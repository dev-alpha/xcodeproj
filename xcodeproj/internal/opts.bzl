"""Functions for processing compiler and linker options."""

load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")
load("@build_bazel_rules_swift//swift:swift.bzl", "SwiftInfo")

# C and C++ compiler flags that we don't want to propagate to Xcode.
# The values are the number of flags to skip, 1 being the flag itself, 2 being
# another flag right after it, etc.
_CC_SKIP_COPTS = {
    "-isysroot": 2,
    "-mios-simulator-version-min": 1,
    "-miphoneos-version-min": 1,
    "-mmacosx-version-min": 1,
    "-mtvos-simulator-version-min": 1,
    "-mtvos-version-min": 1,
    "-mwatchos-simulator-version-min": 1,
    "-mwatchos-version-min": 1,
    "-target": 2,
}

# Swift compiler flags that we don't want to propagate to Xcode.
# The values are the number of flags to skip, 1 being the flag itself, 2 being
# another flag right after it, etc.
_SWIFTC_SKIP_OPTS = {
    "-emit-module-path": 2,
    "-emit-object": 1,
    "-enable-batch-mode": 1,
    # TODO: See if we need to support this
    "-gline-tables-only": 1,
    "-module-name": 2,
    "-num-threads": 2,
    "-output-file-map": 2,
    "-parse-as-library": 1,
    "-sdk": 2,
    "-target": 2,
    # TODO: Make sure we should skip _all_ of these
    "-Xcc": 2,
    # TODO: Make sure we should skip _all_ of these
    "-Xfrontend": 2,
    "-Xwrapped-swift": 1,
}

# Maps Swift compliation mode compiler flags to the corresponding Xcode values
_SWIFT_COMPILATION_MODE_OPTS = {
    "-incremental": "singlefile",
    "-no-whole-module-optimization": "singlefile",
    "-whole-module-optimization": "wholemodule",
    "-wmo": "wholemodule",
}

# Defensive list of features that can appear in the CC toolchain, but that we
# definitely don't want to enable (meaning we don't want them to contribute
# command line flags).
_UNSUPPORTED_CC_FEATURES = [
    "debug_prefix_map_pwd_is_dot",
    # TODO: See if we need to exclude or handle it properly
    "thin_lto",
    "module_maps",
    "use_header_modules",
    "fdo_instrument",
    "fdo_optimize",
]

# Compiler option processing

def _get_unprocessed_compiler_opts(ctx, target):
    """Returns the unprocessed compiler options for the given target.

    Args:
        ctx: The aspect context.
        target: The `Target` that the compiler options will be retrieved from.

    Returns:
        A tuple containing three elements:

        *   A list of C compiler options.
        *   A list of C++ compiler options.
        *   A list of Swift compiler options.
    """
    cc_toolchain = find_cpp_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + _UNSUPPORTED_CC_FEATURES,
    )
    variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = [],
    )

    base_copts = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = "c-compile",
        variables = variables,
    )
    base_cxxopts = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = "c++-compile",
        variables = variables,
    )

    # TODO: Handle perfileopts somehow?

    if SwiftInfo in target:
        # Rule level swiftcopts are included in action.argv below
        rule_copts = []
    elif CcInfo in target:
        rule_copts = getattr(ctx.rule.attr, "copts", [])
        rule_copts = _expand_make_variables(ctx, rule_copts, "copts")
    else:
        rule_copts = []

    raw_swiftcopts = []
    for action in target.actions:
        if action.mnemonic == "SwiftCompile":
            # First two arguments are "worker" and "swiftc"
            raw_swiftcopts = action.argv[2:]

    cpp = ctx.fragments.cpp

    return (
        base_copts + cpp.copts + cpp.conlyopts + rule_copts,
        base_cxxopts + cpp.copts + cpp.cxxopts + rule_copts,
        raw_swiftcopts,
    )

def _process_base_compiler_opts(opts, skip_opts, custom_parsing = None):
    """Process compiler options, skipping options that should be skipped.

    Args:
        opts: A list of compiler options.
        skip_opts: A dictionary of options to skip. The values are the number of
            arguments to skip.
        custom_parsing: A function provides further processing of an option.
            Returns `True` if the option was handled, `False` otherwise.

    Returns:
        A list of unhandled options.
    """
    unhandled_opts = []
    skip_next = 0
    for opt in opts:
        if skip_next:
            skip_next -= 1
            continue
        if opt.find("__BAZEL_XCODE_") != -1:
            # Theses options are already handled by Xcode
            continue
        root_opt = opt.split("=")[0]
        skip_next = skip_opts.get(root_opt, 0)
        if skip_next:
            skip_next -= 1
            continue
        if custom_parsing and custom_parsing(opt):
            continue
        unhandled_opts.append(opt)

    return unhandled_opts

def _process_conlyopts(opts):
    """Processes C compiler options.

    Args:
        opts: A list of C compiler options.

    Returns:
        A tuple containing two elements:

        *   A list of unhandled C compiler options.
        *   A list of C compiler optimization levels parsed.
    """
    optimizations = []
    def process(opt):
        if opt.startswith("-O"):
            optimizations.append(opt[2:])
            return True
        return False

    unhandled_opts = _process_base_compiler_opts(
        opts, _CC_SKIP_COPTS, process,
    )

    return unhandled_opts, optimizations

def _process_cxxopts(opts, build_settings):
    """Processes C++ compiler options.

    Args:
        opts: A list of C++ compiler options.
        build_settings: A mutable dictionary that will be updated with build
            settings that are parsed from `opts`.

    Returns:
        A tuple containing two elements:

        *   A list of unhandled C++ compiler options.
        *   A list of C++ compiler optimization levels parsed.
    """
    optimizations = []
    def process(opt):
        if opt.startswith("-O"):
            optimizations.append(opt[2:])
            return True
        if opt.startswith("-std="):
            build_settings["CLANG_CXX_LANGUAGE_STANDARD"] = _xcode_std_value(
                opt[5:],
            )
            return True
        if opt.startswith("-stdlib="):
            build_settings["CLANG_CXX_LIBRARY"] = opt[8:]
            return True
        return False

    unhandled_opts = _process_base_compiler_opts(
        opts, _CC_SKIP_COPTS, process,
    )

    return unhandled_opts, optimizations

def _process_copts(conlyopts, cxxopts, build_settings):
    """Processes C and C++ compiler options.

    Args:
        conlyopts: A list of C compiler options.
        cxxopts: A list of C++ compiler options.
        build_settings: A mutable dictionary that will be updated with build
            settings that are parsed from `conlyopts` and `cxxopts`.

    Returns:
        A tuple containing two elements:

        *   A list of unhandled C compiler options.
        *   A list of unhandled C++ compiler options.
    """
    conlyopts, conly_optimizations = _process_conlyopts(conlyopts)
    cxxopts, cxx_optimizations = _process_cxxopts(
        cxxopts,
        build_settings,
    )

    # Calculate GCC_OPTIMIZATION_LEVEL, preserving C/C++ specific settings
    if conly_optimizations:
        default_conly_optimization = conly_optimizations[0]
        conly_optimizations = conly_optimizations[1:]
    else:
        default_conly_optimization = "0"
    if cxx_optimizations:
        default_cxx_optimization = cxx_optimizations[0]
        cxx_optimizations = cxx_optimizations[1:]
    else:
        default_cxx_optimization = "0"
    if default_conly_optimization == default_cxx_optimization:
        gcc_optimization = default_conly_optimization
    else:
        gcc_optimization = "0"
        conly_optimizations = [default_conly_optimization] + conly_optimizations
        cxx_optimizations = [default_cxx_optimization] + cxx_optimizations
    build_settings["GCC_OPTIMIZATION_LEVEL"] = gcc_optimization

    return conly_optimizations + conlyopts, cxx_optimizations + cxxopts

def _process_swiftcopts(opts, build_settings):
    """Processes Swift compiler options.

    Args:
        opts: A list of Swift compiler options.
        build_settings: A mutable dictionary that will be updated with build
            settings that are parsed from `opts`.

    Returns:
        A list of unhandled Swift compiler options.
    """
    defines = []
    def process(opt):
        if opt.startswith("-O"):
            build_settings["SWIFT_OPTIMIZATION_LEVEL"] = opt
            return True
        if opt.startswith("-I"):
            return True
        if opt == "-enable-testing":
            build_settings["ENABLE_TESTABILITY"] = True
            return True
        compilation_mode = _SWIFT_COMPILATION_MODE_OPTS.get(opt, "")
        if compilation_mode:
            build_settings["SWIFT_COMPILATION_MODE"] = compilation_mode
            return True
        if opt.startswith("-D"):
            defines.append(opt[2:])
            return True
        if opt.endswith(".swift"):
            # These are the files to compile, not options. They are seen here
            # because of the way we collect Swift compiler options. Ideally in
            # the future we could collect Swift compiler options similar to how
            # we collect C and C++ compiler options.
            return True
        return False

    # Xcode's default is `-O` when not set, so minimally set it to `-Onone`,
    # which matches swiftc's default.
    build_settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone"

    unhandled_opts = _process_base_compiler_opts(
        opts, _SWIFTC_SKIP_OPTS, process
    )

    _set_not_empty(
        build_settings,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
        defines,
    )

    return unhandled_opts

def _process_compiler_opts(ctx, target, build_settings):
    """Processes the compiler options for a target.

    Args:
        ctx: The aspect context.
        target: The `Target` that the compiler options will be retrieved from.
        build_settings: A mutable dictionary that will be updated with build
            settings that are parsed from the target's compiler options.
    """
    raw_conlyopts, raw_cxxopts, raw_swiftcopts = _get_unprocessed_compiler_opts(
        ctx, target,
    )

    conlyopts, cxxopts = _process_copts(
        raw_conlyopts,
        raw_cxxopts,
        build_settings,
    )
    swiftcopts = _process_swiftcopts(raw_swiftcopts, build_settings)

    # TODO: Split out `WARNING_CFLAGS`? (Must maintain order, and only ones that apply to both c and cxx)
    # TODO: Split out `GCC_PREPROCESSOR_DEFINITIONS`? (Must maintain order, and only ones that apply to both c and cxx)
    # TODO: Handle `defines` and `local_defines` as well

    _set_not_empty(
        build_settings,
        "OTHER_CFLAGS",
        conlyopts,
    )
    _set_not_empty(
        build_settings,
        "OTHER_CPLUSPLUSFLAGS",
        cxxopts,
    )
    _set_not_empty(
        build_settings,
        "OTHER_SWIFT_FLAGS",
        swiftcopts,
    )

# Linker option parsing

def _process_linker_opts(ctx, build_settings):
    """Processes the linker options for a target.

    Args:
        ctx: The aspect context.
        build_settings: A mutable dictionary that will be updated with build
            settings that are parsed from the target's linker options.
    """
    rule_linkopts = getattr(ctx.rule.attr, "linkopts", [])
    rule_linkopts = _expand_make_variables(ctx, rule_linkopts, "linkopts")

    _set_not_empty(
        build_settings,
        "OTHER_LDFLAGS",
        ctx.fragments.cpp.linkopts + rule_linkopts,
    )

# Utility

def _expand_make_variables(ctx, values, attribute_name):
    """Expands all references to Make variables in each of the given values.

    Args:
        ctx: The aspect context.
        values: A list of strings, which may contain Make variable placeholders.
        attribute_name: The attribute name string that will be presented in the
            console when an error occurs.

    Returns:
        A list of strings with Make variables placeholders filled in.
    """
    return [
        ctx.expand_make_variables(attribute_name, value, {})
        for value in values
    ]

def _set_not_empty(build_settings, key, value):
    """Sets `build_settings[key]` to `value` if `value` is not empty.

    This is useful for setting build settings that are lists, but only when we
    have a value to set.
    """
    if value:
        build_settings[key] = value

def _xcode_std_value(std):
    """Converts a '-std' option value to an Xcode recognized value."""
    if std.endswith("11"):
        # Xcode encodes "c++11" as "c++0x"
        return std[:-2] + "0x"
    return std

# API

def process_opts(ctx, target):
    """Processes the compiler and linker options for a target.

    Args:
        ctx: The aspect context.
        target: The `Target` that the compiler and linker options will be
            retrieved from.

    Returns:
        A dictionary of Xcode build settings that correspond to the compiler and
        linker options for the target.
    """
    build_settings = {}
    _process_compiler_opts(ctx, target, build_settings)
    _process_linker_opts(ctx, build_settings)
    return build_settings