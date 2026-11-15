load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "MessageNoteEditorScreen",
    module_name = "MessageNoteEditorScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/TextFormat:TextFormat",
    ],
    visibility = [
        "//visibility:public",
    ],
)
