load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")
load("@build_bazel_rules_apple//apple:ios.bzl", "ios_unit_test")
load("@build_bazel_rules_apple//apple/testing/default_runner:ios_test_runner.bzl", "ios_test_runner")

swift_library(
    name = "SharedMessageSetupScreen",
    module_name = "SharedMessageSetupScreen",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/AsyncDisplayKit:AsyncDisplayKit",
        "//submodules/Display:Display",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/AccountContext:AccountContext",
        "//submodules/AvatarNode:AvatarNode",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/ItemListPeerItem:ItemListPeerItem",
        "//submodules/TelegramUIPreferences:TelegramUIPreferences",
        "//submodules/CheckNode:CheckNode",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/ComponentFlow",
        "//submodules/TelegramUI/Components/ButtonComponent",
        "//submodules/TelegramUI/Components/EdgeEffect",
        "//submodules/AppBundle:AppBundle",
        "//submodules/ContextUI:ContextUI",
        "//submodules/UndoUI:UndoUI",
        "//submodules/TextFormat:TextFormat",
        "//submodules/TelegramStringFormatting:TelegramStringFormatting",
        "//submodules/TelegramUI/Components/RichTextEditor:RichTextEditorCore",
        "//submodules/TelegramUI/Components/RichTextAttachmentScreen",
        "//submodules/TelegramUI/Components/GlassControls",
        "//submodules/Components/BundleIconComponent",
        "//submodules/TelegramUI/Components/Chat/ChatRichTextEditorComposer",
        "//submodules/TelegramUI/Components/RichTextEditorMessageConversion",
        "//submodules/Components/ViewControllerComponent:ViewControllerComponent",
        "//submodules/Components/ResizableSheetComponent",
        "//submodules/Components/MultilineTextComponent",
        "//submodules/TelegramUI/Components/ListSectionComponent",
        "//submodules/TelegramUI/Components/ListActionItemComponent",
        "//submodules/TelegramUI/Components/GlassBarButtonComponent",
    ],
    visibility = [
        "//visibility:public",
    ],
)

# The pure half of the room transport: payload diff/apply, topic replay (sessions, snapshots,
# restores) and the message marker round trip. Run with
# `Make.py test --target //submodules/TelegramUI/Components/SharedMessageSetupScreen:SharedMessageSetupScreenTests`.
swift_library(
    name = "SharedMessageSetupScreenTestsLib",
    testonly = True,
    srcs = glob([
        "Tests/**/*.swift",
    ]),
    deps = [
        ":SharedMessageSetupScreen",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramUI/Components/RichTextEditor:RichTextEditorCore",
    ],
)

ios_test_runner(
    name = "SharedMessageSetupScreenTestRunner",
    device_type = "iPhone 18 Pro",
    os_version = "27.0",
)

ios_unit_test(
    name = "SharedMessageSetupScreenTests",
    minimum_os_version = "15.0",
    runner = ":SharedMessageSetupScreenTestRunner",
    deps = [
        ":SharedMessageSetupScreenTestsLib",
    ],
    visibility = [
        "//visibility:public",
    ],
)
