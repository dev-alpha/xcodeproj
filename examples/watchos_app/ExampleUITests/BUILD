load("@build_bazel_rules_apple//apple:ios.bzl", "ios_ui_test")
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

ios_ui_test(
    name = "ExampleUITests",
    bundle_id = "io.buildbuddy.example.uitests",
    minimum_os_version = "15.0",
    test_host = "//examples/watchos_app/Example",
    visibility = ["//visibility:public"],
    deps = [":ExampleUITests.library"],
)

swift_library(
    name = "ExampleUITests.library",
    testonly = True,
    srcs = [":Sources"],
    module_name = "ExampleUITests",
    tags = ["manual"],
)

filegroup(
    name = "Sources",
    srcs = glob(["**/*.swift"]),
)
