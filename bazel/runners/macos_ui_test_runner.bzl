"""A macOS UI test runner built on the rules_apple xctestrun flow."""

load("@apple_support//lib:xcode_support.bzl", "xcode_support")
load("@build_bazel_rules_apple//apple:providers.bzl", "apple_provider")

def _get_xctestrun_template_substitutions(xcode_config):
    if not xcode_config.xcode_version():
        return {
            "%(xctestrun_insert_libraries)s": "",
        }

    if xcode_support.is_xcode_at_least_version(xcode_config, "10.0"):
        xctestrun_insert_libraries = [
            "__PLATFORMS__/MacOSX.platform/Developer/usr/lib/libXCTestBundleInject.dylib",
            "__DEVELOPERUSRLIB__/libMainThreadChecker.dylib",
        ]
    else:
        xctestrun_insert_libraries = [
            "__PLATFORMS__/MacOSX.platform/Developer/Library/PrivateFrameworks/IDEBundleInjection.framework/IDEBundleInjection",
        ]

    subs = {
        "xctestrun_insert_libraries": ":".join(xctestrun_insert_libraries),
    }

    return {"%(" + k + ")s": subs[k] for k in subs}

def _get_template_substitutions(
        *,
        xctestrun_template,
        pre_action_binary,
        post_action_binary,
        post_action_determines_exit_code):
    subs = {
        "xctestrun_template": xctestrun_template.short_path,
        "pre_action_binary": pre_action_binary,
        "post_action_binary": post_action_binary,
        "post_action_determines_exit_code": post_action_determines_exit_code,
    }

    return {"%(" + k + ")s": subs[k] for k in subs}

def _get_execution_environment(xcode_config):
    execution_environment = {}
    xcode_version = str(xcode_config.xcode_version())
    if xcode_version:
        execution_environment["XCODE_VERSION_OVERRIDE"] = xcode_version

    return execution_environment

def _macos_ui_test_runner_impl(ctx):
    preprocessed_xctestrun_template = ctx.actions.declare_file(
        "{}.generated.xctestrun".format(ctx.label.name),
    )

    xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig]

    ctx.actions.expand_template(
        template = ctx.file._xctestrun_template,
        output = preprocessed_xctestrun_template,
        substitutions = _get_xctestrun_template_substitutions(xcode_config),
    )

    runfiles = ctx.runfiles(files = [preprocessed_xctestrun_template])

    default_action_binary = "/usr/bin/true"
    pre_action_binary = default_action_binary
    post_action_binary = default_action_binary

    if ctx.executable.pre_action:
        pre_action_binary = ctx.executable.pre_action.short_path
        runfiles = runfiles.merge(ctx.attr.pre_action[DefaultInfo].default_runfiles)

    post_action_determines_exit_code = False
    if ctx.executable.post_action:
        post_action_binary = ctx.executable.post_action.short_path
        post_action_determines_exit_code = ctx.attr.post_action_determines_exit_code
        runfiles = runfiles.merge(ctx.attr.post_action[DefaultInfo].default_runfiles)

    ctx.actions.expand_template(
        template = ctx.file._test_template,
        output = ctx.outputs.test_runner_template,
        substitutions = _get_template_substitutions(
            xctestrun_template = preprocessed_xctestrun_template,
            pre_action_binary = pre_action_binary,
            post_action_binary = post_action_binary,
            post_action_determines_exit_code = "true" if post_action_determines_exit_code else "false",
        ),
        is_executable = True,
    )

    return [
        apple_provider.make_apple_test_runner_info(
            test_runner_template = ctx.outputs.test_runner_template,
            execution_requirements = {"requires-darwin": ""},
            execution_environment = _get_execution_environment(xcode_config),
        ),
        DefaultInfo(runfiles = runfiles),
    ]

macos_ui_test_runner = rule(
    implementation = _macos_ui_test_runner_impl,
    attrs = {
        "pre_action": attr.label(
            executable = True,
            cfg = "exec",
        ),
        "post_action": attr.label(
            executable = True,
            cfg = "exec",
        ),
        "post_action_determines_exit_code": attr.bool(default = False),
        "_test_template": attr.label(
            default = Label("//bazel/runners:macos_ui_test_runner.template.sh"),
            allow_single_file = True,
        ),
        "_xcode_config": attr.label(
            default = configuration_field(
                fragment = "apple",
                name = "xcode_config_label",
            ),
        ),
        "_xctestrun_template": attr.label(
            default = Label("//bazel/runners:macos_ui_test_runner.template.xctestrun"),
            allow_single_file = True,
        ),
    },
    outputs = {
        "test_runner_template": "%{name}.sh",
    },
    fragments = ["apple", "objc"],
)
