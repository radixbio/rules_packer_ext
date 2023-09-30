load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")


def guestfish_dependencies():
    maybe(
        http_archive,
        name = "guestfish",
        url = "https://europe.mirror.pkgbuild.com/extra/os/x86_64/libguestfs-1.50.1-1-x86_64.pkg.tar.zst",
        build_file_content = """
            exports_files([
                "usr/bin/guestfish",
                "usr/bin/guestmount",
                "usr/bin/guestunmount",
                "usr/bin/libguestfs-make-fixed-appliance",
                "usr/bin/libguestfs-test-tool",
                "usr/bin/virt-copy-in",
                "usr/bin/virt-copy-out",
                "usr/bin/virt-rescue",
                "usr/bin/virt-tar-in",
                "usr/bin/virt-tar-out",
                "usr/lib/guestfs/supermin.d/base.tar.gz",
                "usr/lib/guestfs/supermin.d/daemon.tar.gz",
                "usr/lib/guestfs/supermin.d/excludefiles",
                "usr/lib/guestfs/supermin.d/hostfiles",
                "usr/lib/guestfs/supermin.d/init.tar.gz",
                "usr/lib/guestfs/supermin.d/packages",
                "usr/lib/guestfs/supermin.d/udev-rules.tar.gz",
                "usr/lib/libguestfs-gobject-1.0.so",
                "usr/lib/libguestfs-gobject-1.0.so.0",
                "usr/lib/libguestfs-gobject-1.0.so.0.0.0",
                "usr/lib/libguestfs.so",
                "usr/lib/libguestfs.so.0",
                "usr/lib/libguestfs.so.0.513.0",
                "usr/lib/libguestfs_jni.so",
                "usr/lib/libguestfs_jni.so.1",
                "usr/lib/libguestfs_jni.so.1.50.1",
        ])
        """
    )
