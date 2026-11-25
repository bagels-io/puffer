import Foundation

/// Apps where typing a colon and a word means something else, so emoji
/// suggestions would get in the way: terminals and code editors (`:wq` in
/// vim, `:ok` in Elixir, an editor's own completion on Tab), and chat apps
/// that already have an emoji picker of their own.
public enum EmojiApps {
    static let excluded: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
        "dev.warp.Warp-Stable", "co.zeit.hyper",
        // Code editors
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
        "com.apple.dt.Xcode", "dev.zed.Zed", "com.sublimetext.4", "com.panic.Nova",
        "com.vscodium", "com.exafunction.windsurf",
        // Chat apps with their own :emoji picker
        "com.tinyspeck.slackmacgap", "com.hnc.Discord",
    ]

    /// Bundle id prefixes for families of apps (every JetBrains IDE).
    static let excludedPrefixes = ["com.jetbrains."]

    public static func suggestionsAllowed(in bundleID: String?) -> Bool {
        guard let bundleID else { return true }
        return !excluded.contains(bundleID) && !excludedPrefixes.contains { bundleID.hasPrefix($0) }
    }
}
