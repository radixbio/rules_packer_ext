load("@com_github_rules_packer_config//:config.bzl", "PACKER_ARCH", "PACKER_BIN_NAME", "PACKER_DEBUG", "PACKER_GLOBAL_SUBS", "PACKER_OS", "PACKER_SHAS", "PACKER_VERSION")

def _guestfish_impl(ctx):
    pass

guestfish = rule(
    implementation = _guestfish_impl,
    attrs = {
        "script": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "input_img": attr.label(
            mandatory = False,
        ),
        "input_img_subs_key": attr.string(
            default = "{img}",
        ),
        "substitutions": attr.string_dict(),
    },
)
