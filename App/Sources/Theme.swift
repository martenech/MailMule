import AppKit
import Observation
import SwiftUI

/// Themes work like in Pathfinder: a preset colors the sidebar, content, bars and accent;
/// dark and light palettes force their appearance so system text stays readable.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Systém"
        case .light: "Svetlý"
        case .dark: "Tmavý"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct ThemePreset: Identifiable, Hashable {
    enum SidebarStyle: Hashable {
        /// The system's translucent sidebar.
        case system
        /// Mailmule's dark sidebar with mountains.
        case mailmule
        /// A solid color from the palette.
        case color(Color)
    }

    let id: String
    let name: String
    var appearance: AppearanceMode? = nil
    var accent: Color? = nil
    /// Background of the thread list and the open thread; nil keeps the system colors.
    var content: Color? = nil
    /// Background of the bars (search, actions, quick reply).
    var chrome: Color? = nil
    /// See-through window that blends with the desktop.
    var translucent = false
    var sidebar: SidebarStyle = .system

    /// The sidebar is dark (white text), so its content is drawn in dark mode.
    var hasDarkSidebar: Bool {
        switch sidebar {
        case .mailmule: true
        case .color: appearance == .dark
        case .system: false
        }
    }

    static let all: [ThemePreset] = [
        ThemePreset(id: "mailmule", name: "Mailmule", sidebar: .mailmule),
        ThemePreset(id: "system", name: "Systém"),
        ThemePreset(id: "glass", name: "Glass", translucent: true),
        ThemePreset(id: "nord", name: "Nord", appearance: .dark, accent: Color(hex: "88C0D0"),
                    content: Color(hex: "2E3440"), chrome: Color(hex: "3B4252"), sidebar: .color(Color(hex: "2B303B"))),
        ThemePreset(id: "dracula", name: "Dracula", appearance: .dark, accent: Color(hex: "BD93F9"),
                    content: Color(hex: "282A36"), chrome: Color(hex: "21222C"), sidebar: .color(Color(hex: "21222C"))),
        ThemePreset(id: "midnight", name: "Midnight", appearance: .dark, accent: Color(hex: "4F8CFF"),
                    content: Color(hex: "0D1117"), chrome: Color(hex: "161B22"), sidebar: .color(Color(hex: "010409"))),
        ThemePreset(id: "navy", name: "Navy", appearance: .dark, accent: Color(hex: "2F7BFF"),
                    content: Color(hex: "121729"), chrome: Color(hex: "0E1222"), sidebar: .color(Color(hex: "0E1222"))),
        ThemePreset(id: "catppuccin-mocha", name: "Catppuccin Mocha", appearance: .dark, accent: Color(hex: "CBA6F7"),
                    content: Color(hex: "1E1E2E"), chrome: Color(hex: "181825"), sidebar: .color(Color(hex: "181825"))),
        ThemePreset(id: "tokyo-night", name: "Tokyo Night", appearance: .dark, accent: Color(hex: "7AA2F7"),
                    content: Color(hex: "1A1B26"), chrome: Color(hex: "16161E"), sidebar: .color(Color(hex: "16161E"))),
        ThemePreset(id: "gruvbox-dark", name: "Gruvbox Dark", appearance: .dark, accent: Color(hex: "FABD2F"),
                    content: Color(hex: "282828"), chrome: Color(hex: "1D2021"), sidebar: .color(Color(hex: "1D2021"))),
        ThemePreset(id: "one-dark", name: "One Dark", appearance: .dark, accent: Color(hex: "61AFEF"),
                    content: Color(hex: "282C34"), chrome: Color(hex: "21252B"), sidebar: .color(Color(hex: "21252B"))),
        ThemePreset(id: "rose-pine", name: "Rosé Pine", appearance: .dark, accent: Color(hex: "C4A7E7"),
                    content: Color(hex: "191724"), chrome: Color(hex: "1F1D2E"), sidebar: .color(Color(hex: "1F1D2E"))),
        ThemePreset(id: "monokai", name: "Monokai", appearance: .dark, accent: Color(hex: "A6E22E"),
                    content: Color(hex: "272822"), chrome: Color(hex: "1E1F1C"), sidebar: .color(Color(hex: "1E1F1C"))),
        ThemePreset(id: "everforest", name: "Everforest", appearance: .dark, accent: Color(hex: "A7C080"),
                    content: Color(hex: "2D353B"), chrome: Color(hex: "232A2E"), sidebar: .color(Color(hex: "232A2E"))),
        ThemePreset(id: "kanagawa", name: "Kanagawa", appearance: .dark, accent: Color(hex: "7E9CD8"),
                    content: Color(hex: "1F1F28"), chrome: Color(hex: "16161D"), sidebar: .color(Color(hex: "16161D"))),
        ThemePreset(id: "solarized-dark", name: "Solarized Dark", appearance: .dark, accent: Color(hex: "268BD2"),
                    content: Color(hex: "002B36"), chrome: Color(hex: "073642"), sidebar: .color(Color(hex: "00252F"))),
        ThemePreset(id: "solarized", name: "Solarized Light", appearance: .light, accent: Color(hex: "268BD2"),
                    content: Color(hex: "FDF6E3"), chrome: Color(hex: "EEE8D5"), sidebar: .color(Color(hex: "EEE8D5"))),
        ThemePreset(id: "catppuccin-latte", name: "Catppuccin Latte", appearance: .light, accent: Color(hex: "8839EF"),
                    content: Color(hex: "EFF1F5"), chrome: Color(hex: "E6E9EF"), sidebar: .color(Color(hex: "DCE0E8"))),
        ThemePreset(id: "rose-pine-dawn", name: "Rosé Pine Dawn", appearance: .light, accent: Color(hex: "907AA9"),
                    content: Color(hex: "FAF4ED"), chrome: Color(hex: "F2E9E1"), sidebar: .color(Color(hex: "F2E9E1"))),
        ThemePreset(id: "gruvbox-light", name: "Gruvbox Light", appearance: .light, accent: Color(hex: "076678"),
                    content: Color(hex: "FBF1C7"), chrome: Color(hex: "F2E5BC"), sidebar: .color(Color(hex: "F2E5BC"))),
        ThemePreset(id: "github-light", name: "GitHub Light", appearance: .light, accent: Color(hex: "0969DA"),
                    content: Color(hex: "FFFFFF"), chrome: Color(hex: "F6F8FA"), sidebar: .color(Color(hex: "F6F8FA"))),
        ThemePreset(id: "nord-light", name: "Nord Light", appearance: .light, accent: Color(hex: "5E81AC"),
                    content: Color(hex: "ECEFF4"), chrome: Color(hex: "E5E9F0"), sidebar: .color(Color(hex: "D8DEE9"))),
        ThemePreset(id: "tokyo-night-day", name: "Tokyo Night Day", appearance: .light, accent: Color(hex: "2E7DE9"),
                    content: Color(hex: "E1E2E7"), chrome: Color(hex: "D5D6DB"), sidebar: .color(Color(hex: "D0D5E3"))),
        ThemePreset(id: "one-light", name: "One Light", appearance: .light, accent: Color(hex: "4078F2"),
                    content: Color(hex: "FAFAFA"), chrome: Color(hex: "F0F0F1"), sidebar: .color(Color(hex: "E5E5E6"))),
        ThemePreset(id: "everforest-light", name: "Everforest Light", appearance: .light, accent: Color(hex: "8DA101"),
                    content: Color(hex: "FFFBEF"), chrome: Color(hex: "F4F0D9"), sidebar: .color(Color(hex: "EFEBD4"))),
        ThemePreset(id: "kanagawa-lotus", name: "Kanagawa Lotus", appearance: .light, accent: Color(hex: "4D699B"),
                    content: Color(hex: "F2ECBC"), chrome: Color(hex: "E7DBA0"), sidebar: .color(Color(hex: "E5DDB0"))),
        ThemePreset(id: "ayu-light", name: "Ayu Light", appearance: .light, accent: Color(hex: "FA8D3E"),
                    content: Color(hex: "FCFCFC"), chrome: Color(hex: "F3F4F5"), sidebar: .color(Color(hex: "EDEFF1"))),
        ThemePreset(id: "alucard", name: "Alucard", appearance: .light, accent: Color(hex: "644AC9"),
                    content: Color(hex: "FFFBEB"), chrome: Color(hex: "F5F0DA"), sidebar: .color(Color(hex: "EDE7CF"))),
        ThemePreset(id: "paper", name: "Papier", appearance: .light, accent: Color(hex: "C2410C"),
                    content: Color(hex: "FFFFFF"), chrome: Color(hex: "F7F5F2"), sidebar: .color(Color(hex: "EFEBE4"))),
    ]
}

/// What is drawn behind the sidebar.
enum SidebarBackground: Equatable {
    case theme
    case builtin(Int)
    case custom(URL)

    /// Every numbered image in the bundle, so new backgrounds only need to be dropped into the folder.
    static let builtins: [Int] = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "jpg", subdirectory: "SidebarBackgrounds") ?? []
        return urls.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.sorted()
    }()

    static func builtinURL(_ number: Int) -> URL? {
        Bundle.main.url(forResource: "\(number)", withExtension: "jpg", subdirectory: "SidebarBackgrounds")
    }

    var url: URL? {
        switch self {
        case .theme: nil
        case .builtin(let number): Self.builtinURL(number)
        case .custom(let url): url
        }
    }

    init(storageValue: String?) {
        guard let value = storageValue else { self = .theme; return }
        if value.hasPrefix("builtin:"), let number = Int(value.dropFirst(8)) {
            self = .builtin(number)
        } else if value.hasPrefix("custom:") {
            self = .custom(URL(fileURLWithPath: String(value.dropFirst(7))))
        } else {
            self = .theme
        }
    }

    var storageValue: String {
        switch self {
        case .theme: "theme"
        case .builtin(let number): "builtin:\(number)"
        case .custom(let url): "custom:\(url.path)"
        }
    }
}

enum SidebarTextContrast: String, CaseIterable {
    case automatic, light, dark

    var title: String {
        switch self {
        case .automatic: "Automatický (odporúčané)"
        case .light: "Svetlý text"
        case .dark: "Tmavý text"
        }
    }
}

@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var appearance: AppearanceMode {
        didSet { save("theme.appearance", appearance.rawValue); applyAppearance() }
    }
    var presetID: String {
        didSet { save("theme.preset", presetID); applyAppearance() }
    }
    var customAccent: Color? {
        didSet { save("theme.accent", customAccent?.hex) }
    }
    /// Mountains and the tagline at the bottom of the sidebar.
    var sidebarDecoration: Bool {
        didSet { save("theme.sidebarDecoration", sidebarDecoration) }
    }
    /// Picture behind the sidebar: the theme's own background, one of the bundled pictures, or the user's.
    var sidebarBackground: SidebarBackground {
        didSet { save("theme.sidebarBackground", sidebarBackground.storageValue); loadSidebarImage() }
    }
    /// How strongly the sidebar picture is darkened (or lightened) so the text stays readable.
    var sidebarScrim: Double {
        didSet { save("theme.sidebarScrim", sidebarScrim) }
    }
    /// Text over the sidebar picture: by its brightness, or forced light/dark.
    var sidebarText: SidebarTextContrast {
        didSet { save("theme.sidebarText", sidebarText.rawValue) }
    }
    private(set) var sidebarImage: NSImage?
    private(set) var sidebarImageIsDark = true

    var backgroundImage: URL? {
        didSet { save("theme.backgroundImage", backgroundImage?.path); loadImage() }
    }
    var backgroundOpacity: Double {
        didSet { save("theme.backgroundOpacity", backgroundOpacity) }
    }

    private(set) var image: NSImage?

    private init() {
        appearance = .system
        presetID = "mailmule"
        sidebarDecoration = true
        sidebarBackground = .theme
        sidebarScrim = 0.3
        sidebarText = .automatic
        backgroundOpacity = 0.2
        reload()
    }

    /// Reads the theme from UserDefaults (at launch, after importing or resetting settings).
    func reload() {
        let defaults = UserDefaults.standard
        appearance = defaults.string(forKey: "theme.appearance").flatMap(AppearanceMode.init(rawValue:)) ?? .system
        presetID = defaults.string(forKey: "theme.preset") ?? "mailmule"
        customAccent = defaults.string(forKey: "theme.accent").map(Color.init(hex:))
        sidebarDecoration = defaults.object(forKey: "theme.sidebarDecoration") as? Bool ?? true
        backgroundImage = defaults.string(forKey: "theme.backgroundImage").map { URL(fileURLWithPath: $0) }
        backgroundOpacity = defaults.object(forKey: "theme.backgroundOpacity") as? Double ?? 0.2
        sidebarBackground = SidebarBackground(storageValue: defaults.string(forKey: "theme.sidebarBackground"))
        sidebarScrim = defaults.object(forKey: "theme.sidebarScrim") as? Double ?? 0.3
        sidebarText = defaults.string(forKey: "theme.sidebarText").flatMap(SidebarTextContrast.init(rawValue:)) ?? .automatic
        loadImage()
        loadSidebarImage()
        applyAppearance()
    }

    /// The sidebar is dark (white text): a dark picture, or a theme with a dark sidebar.
    var sidebarIsDark: Bool {
        guard sidebarImage != nil else { return preset.hasDarkSidebar }
        switch sidebarText {
        case .automatic: return sidebarImageIsDark
        case .light: return true
        case .dark: return false
        }
    }

    private func loadSidebarImage() {
        sidebarImage = sidebarBackground.url.flatMap { NSImage(contentsOf: $0) }
        if let sidebarImage { sidebarImageIsDark = Self.averageLuminance(sidebarImage) < 0.5 }
    }

    /// Average brightness of a picture, from a tiny downscaled copy.
    static func averageLuminance(_ image: NSImage) -> Double {
        let size = 16
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0.5 }
        var total = 0.0
        for i in 0..<(size * size) {
            let r = Double(data[i * 4]), g = Double(data[i * 4 + 1]), b = Double(data[i * 4 + 2])
            total += (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        }
        return total / Double(size * size)
    }

    var preset: ThemePreset { ThemePreset.all.first { $0.id == presetID } ?? ThemePreset.all[0] }

    var accent: Color { customAccent ?? preset.accent ?? .accentColor }

    var effectiveAppearance: AppearanceMode { preset.appearance ?? appearance }

    /// Something other than system colors is behind the list, so list backgrounds must be hidden.
    var customizesContent: Bool { preset.content != nil || preset.translucent || image != nil }

    func applyAppearance() {
        NSApp?.appearance = effectiveAppearance.nsAppearance
    }

    private func loadImage() {
        image = backgroundImage.flatMap { NSImage(contentsOf: $0) }
    }

    private func save(_ key: String, _ value: Any?) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

extension Color {
    /// The theme's accent; use instead of `Color.accentColor` so themes can recolor buttons and badges.
    @MainActor static var themeAccent: Color { ThemeStore.shared.accent }

    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hex: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}

/// Behind-window blur for the Glass theme.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.material = material
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Background of the list and thread columns: theme color, glass or background image.
struct ThemedBackground: View {
    var fallback: Color = Color(nsColor: .textBackgroundColor)
    private var theme: ThemeStore { .shared }

    var body: some View {
        ZStack {
            if theme.preset.translucent {
                VisualEffectBackground()
            } else {
                theme.preset.content ?? fallback
            }
            if let image = theme.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(theme.backgroundOpacity)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
}

/// Bars (search, actions, quick reply): the theme's chrome color, or the system bar material.
struct ThemedChrome: ViewModifier {
    private var theme: ThemeStore { .shared }

    func body(content: Content) -> some View {
        if let chrome = theme.preset.chrome {
            content.background(chrome)
        } else if theme.preset.translucent {
            content.background(.ultraThinMaterial)
        } else {
            content.background(.bar)
        }
    }
}

extension View {
    func themedChrome() -> some View { modifier(ThemedChrome()) }
}
