load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

objc_library(
    name = "lib_defines",
    defines = [
        "SECRET_3=\\\"Hello\\\"",
        "SECRET_2=\\\"World!\\\"",
    ],
)

objc_library(
    name = "lib_impl",
    srcs = [
        "lib.m",
        "private.h",
    ],
    tags = ["manual"],
    deps = [
        ":lib_defines",
    ],
)

cc_library(
    name = "private_lib",
    srcs = ["private_lib.c"],
    hdrs = ["private_lib.h"],
    tags = ["swift_module=_Lib"],
)

swift_library(
    name = "lib_swift",
    srcs = ["lib.swift"],
    generated_header_name = "private/LibSwift-Swift.h",
    generates_header = True,
    module_name = "LibSwift",
    private_deps = [":private_lib"],
    visibility = ["//examples/command_line/Tests:__subpackages__"],
    deps = [
        ":lib_impl",
    ],
)

objc_library(
    name = "lib_headers",
    hdrs = ["dir with space/lib.h"],
    includes = [
        "dir with space",
        "private",
    ],
    deps = [
        ":lib_swift",
    ],
)

alias(
    name = "lib",
    actual = ":lib_headers",
    visibility = ["//visibility:public"],
)
