load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "ChatMessageSharedFooterBubbleContentNode",
    module_name = "ChatMessageSharedFooterBubbleContentNode",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Display",
        "//submodules/LottieSettings:LottieSettings",
        "//submodules/AsyncDisplayKit",
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/TelegramCore",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUI/Components/Chat/ChatMessageBubbleContentNode",
        "//submodules/TelegramUI/Components/Chat/ChatMessageItemCommon",
    ],
    visibility = [
        "//visibility:public",
    ],
)
