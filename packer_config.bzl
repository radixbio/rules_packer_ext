_LUT = {
    "macosx": "darwin",
    "aarch64": "arm64",
    "linux": "linux",
    "windows": "windows",
    "amd64": "amd64",
    "i386": "386",  # Untested
    "arm": "arm",
    "ppc64": "ppc64le",  # Untested
    "freebsd": "freebsd",  # Untested
    "netbsd": "netbsd",  # Untested
    "openbsd": "openbsd",  # Untested
    "solaris": "solaris",
}

_PKR_URL = "https://releases.hashicorp.com/packer/{version}/packer_{version}_{os}_{arch}.zip"

def _normalize_intel(str):
    if str == "x86_64":
        return "amd64"
    else:
        return str

def _java_prop_to_hashicorp(str):
    return _LUT[str]

def _hashicorp_to_java_prop(str):
    return {v: k for k, v in _LUT.items()}[str]

def _subst(repository_ctx):
    build_on_os = repository_ctx.os.name.lower()
    if build_on_os == "linux":
        return repository_ctx.attr.linux_substitutions
    elif build_on_os == "macos" or build_on_os == "darwin" or build_on_os == "mac os x":
        return repository_ctx.attr.macos_substitutions
    else:
        fail("cannot find substitutions for platform " + build_on_os)

def _packer_configure_impl(repository_ctx):
    packer_version = repository_ctx.attr.packer_version
    repository_ctx.download(
        url = "https://releases.hashicorp.com/packer/{version}/packer_{version}_SHA256SUMS".format(version = packer_version),
        output = "packer_{version}_shas.txt".format(version = packer_version),
    )
    shas = repository_ctx.read(
        "packer_{version}_shas.txt".format(version = packer_version),
    )
    shas = {x[66 + len("packer_{version}_".format(version = packer_version)):-4]: x[:64] for x in shas.split("\n")}
    shas = [{k.split("_")[0]: {k.split("_")[1]: v}} for k, v in shas.items() if k.find("_") != -1]
    os_arch_sha = {}
    for d in shas:
        (os, inner) = d.popitem()
        (arch, sha) = inner.popitem()
        url = _PKR_URL.format(
            version = packer_version,
            os = os,
            arch = arch,
        )
        existing_inner = os_arch_sha.get(_hashicorp_to_java_prop(os), {_hashicorp_to_java_prop(arch): (url, sha)})
        existing_inner.update([(_hashicorp_to_java_prop(arch), (url, sha))])
        os_arch_sha.update([(_hashicorp_to_java_prop(os), existing_inner)])

    packer_bin_name = None
    if repository_ctx.os.name == "windows":
        packer_bin_name = "packer.exe"
    else:
        packer_bin_name = "packer"

    packer_display = ""
    if "DISPLAY" in repository_ctx.os.environ:
        packer_display = repository_ctx.os.environ["DISPLAY"]

    config_file_content = """
    PACKER_VERSION="{packer_version}"
    PACKER_OS="{os}"
    PACKER_ARCH="{arch}"
    PACKER_SHAS={packer_shas}
    PACKER_BIN_NAME="{packer_bin_name}"
    PACKER_GLOBAL_SUBS={global_substitutions}
    PACKER_DEBUG={debug}
    PACKER_QEMU_VERSION="{qemu_version}"
    PACKER_DISPLAY="{packer_display}"
    """.format(
        packer_version = packer_version,
        packer_shas = str(os_arch_sha),
        os = repository_ctx.os.name,
        arch = _normalize_intel(repository_ctx.os.arch),
        packer_bin_name = packer_bin_name,
        global_substitutions = _subst(repository_ctx),
        debug = repository_ctx.attr.debug,
        qemu_version = repository_ctx.attr.qemu_version,
        packer_display = packer_display,
    ).replace(" ", "")

    repository_ctx.file("config.bzl", config_file_content)
    repository_ctx.file("BUILD")

_packer_configure = repository_rule(
    implementation = _packer_configure_impl,
    attrs = {
        "packer_version": attr.string(
            mandatory = True,
        ),
        "qemu_version": attr.string(
            default = "7.2.0",
        ),
        "linux_substitutions": attr.string_dict(),
        "macos_substitutions": attr.string_dict(),
        "debug": attr.bool(
            default = False,
        ),
    },
    environ = [
        "DISPLAY",
    ],
)

def packer_configure(packer_version, qemu_version, linux_substitutions, macos_substitutions, debug):
    _packer_configure(
        name = "com_github_rules_packer_config",
        packer_version = packer_version,
        qemu_version = qemu_version,
        linux_substitutions = linux_substitutions,
        macos_substitutions = macos_substitutions,
        debug = debug,
    )
