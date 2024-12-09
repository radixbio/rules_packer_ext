local_repository(
    name = "com_github_rules_packer",
    path = ".",
)

load("@com_github_rules_packer//:packer_config.bzl", "packer_configure")

packer_configure(
    packer_version = "1.8.6",
    qemu_version = "wip",  # TODO: is it possible to load our own qemu like this?
    global_substitutions = {
        '"{$foo}"': "bar",
        "{http_dir}": ".",
        "{accelerator}": "kvm",
        "{vga}": "qxl",
        "{display}": "none",
        "{headless}": "true",
        "{cpu}": "Cascadelake-Server-v4",
    },
    debug = True,
)

load("@com_github_rules_packer//:packer_dependencies.bzl", "packer_dependencies")

packer_dependencies()

load("@aspect_bazel_lib//lib:repositories.bzl", "aspect_bazel_lib_dependencies")

aspect_bazel_lib_dependencies()

load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive", "http_file")

http_file(
    name = "ubuntu18046_x64",
    sha256 = "f5cbb8104348f0097a8e513b10173a07dbc6684595e331cb06f93f385d0aecf6",
    urls = ["http://cdimage.ubuntu.com/ubuntu/releases/18.04/release/ubuntu-18.04.6-server-amd64.iso"],
)

http_file(
    name = "centos7_x64",
    sha256 = "07b94e6b1a0b0260b94c83d6bb76b26bf7a310dc78d7a9c7432809fb9bc6194a",
    urls = ["http://isoredirect.centos.org/centos/7/isos/x86_64/"],
)
