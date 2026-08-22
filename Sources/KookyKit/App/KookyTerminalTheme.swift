import Foundation
import AppKit

struct KookyTerminalTheme: Identifiable, Hashable {
    static let bundledStoredValuePrefix = "kooky:"
    static let defaultLightID = "one-light"
    static let defaultDarkID = "one-dark"
    static var defaultLightStoredValue: String { bundledStoredValue(for: defaultLightID) }
    static var defaultDarkStoredValue: String { bundledStoredValue(for: defaultDarkID) }

    enum Source: Hashable {
        case bundled
        case ghosttyUser
    }

    let id: String
    let title: String
    let storedValue: String
    let backgroundHex: String
    let foregroundHex: String
    let lines: [String]
    let source: Source

    var isBundled: Bool { source == .bundled }

    /// Light/dark split for the picker's section grouping. Uses the same
    /// luminance threshold `Theme.Resolved` applies when deciding chrome
    /// appearance, so a theme listed under "Dark" is exactly one that renders
    /// dark chrome.
    var isDark: Bool {
        (NSColor(hex: backgroundHex)?.relativeLuminance ?? 0) <= 0.55
    }

    static let presets: [KookyTerminalTheme] = [
        .init(
            id: "catppuccin-frappe",
            title: "Catppuccin Frappe",
            background: "#303446",
            foreground: "#C6D0F5",
            cursor: "#F2D5CF",
            selectionBackground: "#626880",
            selectionForeground: "#C6D0F5",
            palette: [
                "#51576D", "#E78284", "#A6D189", "#E5C890",
                "#8CAAEE", "#F4B8E4", "#81C8BE", "#A5ADCE",
                "#626880", "#E67172", "#8EC772", "#D9BA73",
                "#7B9EF0", "#F2A4DB", "#5ABFB5", "#B5BFE2",
            ]
        ),
        .init(
            id: "catppuccin-latte",
            title: "Catppuccin Latte",
            background: "#EFF1F5",
            foreground: "#4C4F69",
            cursor: "#DC8A78",
            selectionBackground: "#CCD0DA",
            selectionForeground: "#4C4F69",
            palette: [
                "#5C5F77", "#D20F39", "#40A02B", "#DF8E1D",
                "#1E66F5", "#EA76CB", "#179299", "#ACB0BE",
                "#6C6F85", "#D20F39", "#40A02B", "#DF8E1D",
                "#1E66F5", "#EA76CB", "#179299", "#BCC0CC",
            ]
        ),
        .init(
            id: "dracula",
            title: "Dracula",
            background: "#282A36",
            foreground: "#F8F8F2",
            cursor: "#F8F8F2",
            selectionBackground: "#44475A",
            selectionForeground: "#F8F8F2",
            palette: [
                "#000000", "#FF5555", "#50FA7B", "#F1FA8C",
                "#BD93F9", "#FF79C6", "#8BE9FD", "#BBBBBB",
                "#555555", "#FF5555", "#50FA7B", "#F1FA8C",
                "#BD93F9", "#FF79C6", "#8BE9FD", "#FFFFFF",
            ]
        ),
        .init(
            id: "rose-pine",
            title: "Rosé Pine",
            background: "#191724",
            foreground: "#E0DEF4",
            cursor: "#E0DEF4",
            selectionBackground: "#403D52",
            selectionForeground: "#E0DEF4",
            palette: [
                "#26233A", "#EB6F92", "#31748F", "#F6C177",
                "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
                "#6E6A86", "#EB6F92", "#31748F", "#F6C177",
                "#9CCFD8", "#C4A7E7", "#EBBCBA", "#E0DEF4",
            ]
        ),
        .init(
            id: "rose-pine-dawn",
            title: "Rosé Pine Dawn",
            background: "#FAF4ED",
            foreground: "#575279",
            cursor: "#575279",
            selectionBackground: "#DFDAD9",
            selectionForeground: "#575279",
            palette: [
                "#F2E9E1", "#B4637A", "#286983", "#EA9D34",
                "#56949F", "#907AA9", "#D7827E", "#575279",
                "#9893A5", "#B4637A", "#286983", "#EA9D34",
                "#56949F", "#907AA9", "#D7827E", "#575279",
            ]
        ),
        .init(
            id: "solarized-dark",
            title: "Solarized Dark",
            background: "#002B36",
            foreground: "#839496",
            cursor: "#93A1A1",
            selectionBackground: "#073642",
            selectionForeground: "#93A1A1",
            palette: [
                "#073642", "#DC322F", "#859900", "#B58900",
                "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                "#002B36", "#CB4B16", "#586E75", "#657B83",
                "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
            ]
        ),
        .init(
            id: "solarized-light",
            title: "Solarized Light",
            background: "#FDF6E3",
            foreground: "#657B83",
            cursor: "#586E75",
            selectionBackground: "#EEE8D5",
            selectionForeground: "#586E75",
            palette: [
                "#073642", "#DC322F", "#859900", "#B58900",
                "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
                "#002B36", "#CB4B16", "#586E75", "#657B83",
                "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
            ]
        ),
        .init(
            id: "tokyo-night",
            title: "Tokyo Night",
            background: "#1A1B26",
            foreground: "#C0CAF5",
            cursor: "#C0CAF5",
            selectionBackground: "#283457",
            selectionForeground: "#C0CAF5",
            palette: [
                "#15161E", "#F7768E", "#9ECE6A", "#E0AF68",
                "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
                "#414868", "#F7768E", "#9ECE6A", "#E0AF68",
                "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
            ]
        ),
        .init(
            id: "tokyo-day",
            title: "Tokyo Day",
            background: "#E1E2E7",
            foreground: "#3760BF",
            cursor: "#3760BF",
            selectionBackground: "#B7C1E3",
            selectionForeground: "#3760BF",
            palette: [
                "#B4B5B9", "#F52A65", "#587539", "#8C6C3E",
                "#2E7DE9", "#9854F1", "#007197", "#6172B0",
                "#A1A6C5", "#F52A65", "#587539", "#8C6C3E",
                "#2E7DE9", "#9854F1", "#007197", "#3760BF",
            ]
        ),
        .init(
            id: "gruvbox-dark",
            title: "Gruvbox Dark",
            background: "#282828",
            foreground: "#EBDBB2",
            cursor: "#EBDBB2",
            selectionBackground: "#665C54",
            selectionForeground: "#EBDBB2",
            palette: [
                "#282828", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#A89984",
                "#928374", "#FB4934", "#B8BB26", "#FABD2F",
                "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
            ]
        ),
        .init(
            id: "gruvbox-light",
            title: "Gruvbox Light",
            background: "#FBF1C7",
            foreground: "#3C3836",
            cursor: "#3C3836",
            selectionBackground: "#D5C4A1",
            selectionForeground: "#3C3836",
            palette: [
                "#FBF1C7", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#7C6F64",
                "#928374", "#9D0006", "#79740E", "#B57614",
                "#076678", "#8F3F71", "#427B58", "#3C3836",
            ]
        ),
        // Concrete snapshot of libghostty's zero-config colors at the SHA
        // pinned by scripts/setup-libghostty.sh. Unlike the old "Default"
        // picker value, this never inherits a user's Ghostty configuration.
        .init(
            id: "ghostty-dark",
            title: "Ghostty Dark",
            background: "#282C34",
            foreground: "#FFFFFF",
            cursor: "#FFFFFF",
            selectionBackground: "#FFFFFF",
            selectionForeground: "#282C34",
            palette: [
                "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
                "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
                "#666666", "#D54E53", "#B9CA4A", "#E7C547",
                "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA",
            ]
        ),
        .init(
            id: "one-dark",
            title: "One Dark",
            background: "#282C34",
            foreground: "#ABB2BF",
            cursor: "#ABB2BF",
            selectionBackground: "#3E4451",
            selectionForeground: "#ABB2BF",
            palette: [
                "#282C34", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#ABB2BF",
                "#5C6370", "#E06C75", "#98C379", "#E5C07B",
                "#61AFEF", "#C678DD", "#56B6C2", "#FFFFFF",
            ]
        ),
        .init(
            id: "one-light",
            title: "One Light",
            background: "#FAFAFA",
            foreground: "#383A42",
            cursor: "#383A42",
            selectionBackground: "#DBDBDC",
            selectionForeground: "#383A42",
            palette: [
                "#383A42", "#E45649", "#50A14F", "#C18401",
                "#4078F2", "#A626A4", "#0184BC", "#A0A1A7",
                "#696C77", "#E45649", "#50A14F", "#C18401",
                "#4078F2", "#A626A4", "#0184BC", "#FFFFFF",
            ]
        ),
        // Open-source themes also offered by Codex Desktop. These terminal
        // color tables come from @shikijs/themes 3.23.0 (MIT), not from the
        // proprietary Codex application bundle. Alpha selection colors are
        // composited over their terminal backgrounds because Ghostty accepts
        // opaque RGB colors here.
        .init(
            id: "ayu-dark",
            title: "Ayu Dark",
            background: "#0D1017",
            foreground: "#BFBDB6",
            cursor: "#E6B450",
            selectionBackground: "#172E51",
            selectionForeground: "#BFBDB6",
            palette: [
                "#1B1F29", "#F06B73", "#70BF56", "#FDB04C",
                "#4FBFFF", "#D0A1FF", "#93E2C8", "#C7C7C7",
                "#686868", "#F07178", "#AAD94C", "#FFB454",
                "#59C2FF", "#D2A6FF", "#95E6CB", "#FFFFFF",
            ]
        ),
        .init(
            id: "ayu-light",
            title: "Ayu Light",
            background: "#F8F9FA",
            foreground: "#5C6166",
            cursor: "#F29718",
            selectionBackground: "#D3E1F5",
            selectionForeground: "#5C6166",
            palette: [
                "#000000", "#F06B6C", "#6CBF43", "#E7A100",
                "#21A1E2", "#A176CB", "#4ABC96", "#C7C7C7",
                "#686868", "#F07171", "#86B300", "#EBA400",
                "#22A4E6", "#A37ACC", "#4CBF99", "#D1D1D1",
            ]
        ),
        .init(
            id: "ayu-mirage",
            title: "Ayu Mirage",
            background: "#1F2430",
            foreground: "#CCCAC2",
            cursor: "#FFCC66",
            selectionBackground: "#274364",
            selectionForeground: "#CCCAC2",
            palette: [
                "#171B24", "#F28273", "#87D96C", "#FCCA60",
                "#6ACDFF", "#DDBBFF", "#93E2C8", "#C7C7C7",
                "#686868", "#F28779", "#D5FF80", "#FFCD66",
                "#73D0FF", "#DFBFFF", "#95E6CB", "#FFFFFF",
            ]
        ),
        .init(
            id: "catppuccin-macchiato",
            title: "Catppuccin Macchiato",
            background: "#24273A",
            foreground: "#CAD3F5",
            cursor: "#F4DBD6",
            selectionBackground: "#5B6078",
            selectionForeground: "#CAD3F5",
            palette: [
                "#494D64", "#ED8796", "#A6DA95", "#EED49F",
                "#8AADF4", "#F5BDE6", "#8BD5CA", "#A5ADCB",
                "#5B6078", "#EC7486", "#8CCF7F", "#E1C682",
                "#78A1F6", "#F2A9DD", "#63CBC0", "#B8C0E0",
            ]
        ),
        .init(
            id: "catppuccin-mocha",
            title: "Catppuccin Mocha",
            background: "#1E1E2E",
            foreground: "#CDD6F4",
            cursor: "#F5E0DC",
            selectionBackground: "#585B70",
            selectionForeground: "#CDD6F4",
            palette: [
                "#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF",
                "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8",
                "#585B70", "#F37799", "#89D88B", "#EBD391",
                "#74A8FC", "#F2AEDE", "#6BD7CA", "#BAC2DE",
            ]
        ),
        .init(
            id: "dracula-soft",
            title: "Dracula Soft",
            background: "#282A36",
            foreground: "#F6F6F4",
            cursor: "#F6F6F4",
            selectionBackground: "#44475A",
            selectionForeground: "#F6F6F4",
            palette: [
                "#262626", "#EE6666", "#62E884", "#E7EE98",
                "#BF9EEE", "#F286C4", "#97E1F1", "#F6F6F4",
                "#7B7F8B", "#F07C7C", "#78F09A", "#F6F6AE",
                "#D6B4F7", "#F49DDA", "#ADF6F6", "#FFFFFF",
            ]
        ),
        .init(
            id: "everforest-dark",
            title: "Everforest Dark",
            background: "#2D353B",
            foreground: "#D3C6AA",
            cursor: "#D3C6AA",
            selectionBackground: "#414B51",
            selectionForeground: "#D3C6AA",
            palette: [
                "#343F44", "#E67E80", "#A7C080", "#DBBC7F",
                "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA",
                "#859289", "#E67E80", "#A7C080", "#DBBC7F",
                "#7FBBB3", "#D699B6", "#83C092", "#D3C6AA",
            ]
        ),
        .init(
            id: "everforest-light",
            title: "Everforest Light",
            background: "#FDF6E3",
            foreground: "#5C6A72",
            cursor: "#5C6A72",
            selectionBackground: "#EFE9D5",
            selectionForeground: "#5C6A72",
            palette: [
                "#5C6A72", "#F85552", "#8DA101", "#DFA000",
                "#3A94C5", "#DF69BA", "#35A77C", "#939F91",
                "#5C6A72", "#F85552", "#8DA101", "#DFA000",
                "#3A94C5", "#DF69BA", "#35A77C", "#F4F0D9",
            ]
        ),
        .init(
            id: "github-dark-default",
            title: "GitHub Dark",
            background: "#0D1117",
            foreground: "#E6EDF3",
            cursor: "#2F81F7",
            selectionBackground: "#162D4F",
            selectionForeground: "#E6EDF3",
            palette: [
                "#484F58", "#FF7B72", "#3FB950", "#D29922",
                "#58A6FF", "#BC8CFF", "#39C5CF", "#B1BAC4",
                "#6E7681", "#FFA198", "#56D364", "#E3B341",
                "#79C0FF", "#D2A8FF", "#56D4DD", "#FFFFFF",
            ]
        ),
        .init(
            id: "github-dark-dimmed",
            title: "GitHub Dark Dimmed",
            background: "#22272E",
            foreground: "#ADBAC7",
            cursor: "#539BF5",
            selectionBackground: "#2E4460",
            selectionForeground: "#ADBAC7",
            palette: [
                "#545D68", "#F47067", "#57AB5A", "#C69026",
                "#539BF5", "#B083F0", "#39C5CF", "#909DAB",
                "#636E7B", "#FF938A", "#6BC46D", "#DAAA3F",
                "#6CB6FF", "#DCBDFB", "#56D4DD", "#CDD9E5",
            ]
        ),
        .init(
            id: "github-dark-high-contrast",
            title: "GitHub Dark High Contrast",
            background: "#0A0C10",
            foreground: "#F0F3F6",
            cursor: "#71B7FF",
            selectionBackground: "#FFFFFF",
            selectionForeground: "#0A0C10",
            palette: [
                "#7A828E", "#FF9492", "#26CD4D", "#F0B72F",
                "#71B7FF", "#CB9EFF", "#39C5CF", "#D9DEE3",
                "#9EA7B3", "#FFB1AF", "#4AE168", "#F7C843",
                "#91CBFF", "#DBB7FF", "#56D4DD", "#FFFFFF",
            ]
        ),
        .init(
            id: "github-light-default",
            title: "GitHub Light",
            background: "#FFFFFF",
            foreground: "#1F2328",
            cursor: "#0969DA",
            selectionBackground: "#C2DAF6",
            selectionForeground: "#1F2328",
            palette: [
                "#24292F", "#CF222E", "#116329", "#4D2D00",
                "#0969DA", "#8250DF", "#1B7C83", "#6E7781",
                "#57606A", "#A40E26", "#1A7F37", "#633C01",
                "#218BFF", "#A475F9", "#3192AA", "#8C959F",
            ]
        ),
        .init(
            id: "github-light-high-contrast",
            title: "GitHub Light High Contrast",
            background: "#FFFFFF",
            foreground: "#0E1116",
            cursor: "#0349B4",
            selectionBackground: "#0E1116",
            selectionForeground: "#FFFFFF",
            palette: [
                "#0E1116", "#A0111F", "#024C1A", "#3F2200",
                "#0349B4", "#622CBC", "#1B7C83", "#66707B",
                "#4B535D", "#86061D", "#055D20", "#4E2C00",
                "#1168E3", "#844AE7", "#3192AA", "#88929D",
            ]
        ),
        .init(
            id: "gruvbox-dark-hard",
            title: "Gruvbox Dark Hard",
            background: "#1D2021",
            foreground: "#EBDBB2",
            cursor: "#EBDBB2",
            selectionBackground: "#303F33",
            selectionForeground: "#EBDBB2",
            palette: [
                "#3C3836", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#A89984",
                "#928374", "#FB4934", "#B8BB26", "#FABD2F",
                "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
            ]
        ),
        .init(
            id: "gruvbox-dark-soft",
            title: "Gruvbox Dark Soft",
            background: "#32302F",
            foreground: "#EBDBB2",
            cursor: "#EBDBB2",
            selectionBackground: "#404B3E",
            selectionForeground: "#EBDBB2",
            palette: [
                "#3C3836", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#A89984",
                "#928374", "#FB4934", "#B8BB26", "#FABD2F",
                "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
            ]
        ),
        .init(
            id: "gruvbox-light-hard",
            title: "Gruvbox Light Hard",
            background: "#F9F5D7",
            foreground: "#3C3836",
            cursor: "#3C3836",
            selectionBackground: "#D5DFBC",
            selectionForeground: "#3C3836",
            palette: [
                "#EBDBB2", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#7C6F64",
                "#928374", "#9D0006", "#79740E", "#B57614",
                "#076678", "#8F3F71", "#427B58", "#3C3836",
            ]
        ),
        .init(
            id: "gruvbox-light-soft",
            title: "Gruvbox Light Soft",
            background: "#F2E5BC",
            foreground: "#3C3836",
            cursor: "#3C3836",
            selectionBackground: "#CFD3A7",
            selectionForeground: "#3C3836",
            palette: [
                "#EBDBB2", "#CC241D", "#98971A", "#D79921",
                "#458588", "#B16286", "#689D6A", "#7C6F64",
                "#928374", "#9D0006", "#79740E", "#B57614",
                "#076678", "#8F3F71", "#427B58", "#3C3836",
            ]
        ),
        .init(
            id: "material-theme",
            title: "Material",
            background: "#263238",
            foreground: "#EEFFFF",
            cursor: "#FFCB6B",
            selectionBackground: "#31454A",
            selectionForeground: "#EEFFFF",
            palette: [
                "#000000", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
                "#546E7A", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
            ]
        ),
        .init(
            id: "material-theme-darker",
            title: "Material Darker",
            background: "#212121",
            foreground: "#EEFFFF",
            cursor: "#FFCB6B",
            selectionBackground: "#353535",
            selectionForeground: "#EEFFFF",
            palette: [
                "#000000", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
                "#545454", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
            ]
        ),
        .init(
            id: "material-theme-lighter",
            title: "Material Lighter",
            background: "#FAFAFA",
            foreground: "#90A4AE",
            cursor: "#E2931D",
            selectionBackground: "#DBEEEC",
            selectionForeground: "#90A4AE",
            palette: [
                "#000000", "#E53935", "#91B859", "#E2931D",
                "#6182B8", "#9C3EDA", "#39ADB5", "#FFFFFF",
                "#90A4AE", "#E53935", "#91B859", "#E2931D",
                "#6182B8", "#9C3EDA", "#39ADB5", "#FFFFFF",
            ]
        ),
        .init(
            id: "material-theme-ocean",
            title: "Material Ocean",
            background: "#0F111A",
            foreground: "#BABED8",
            cursor: "#FFCB6B",
            selectionBackground: "#2E334A",
            selectionForeground: "#BABED8",
            palette: [
                "#000000", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
                "#464B5D", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
            ]
        ),
        .init(
            id: "material-theme-palenight",
            title: "Material Palenight",
            background: "#292D3E",
            foreground: "#BABED8",
            cursor: "#FFCB6B",
            selectionBackground: "#404663",
            selectionForeground: "#BABED8",
            palette: [
                "#000000", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
                "#676E95", "#F07178", "#C3E88D", "#FFCB6B",
                "#82AAFF", "#C792EA", "#89DDFF", "#FFFFFF",
            ]
        ),
        .init(
            id: "monokai",
            title: "Monokai",
            background: "#272822",
            foreground: "#F8F8F2",
            cursor: "#F8F8F0",
            selectionBackground: "#575A5A",
            selectionForeground: "#F8F8F2",
            palette: [
                "#333333", "#C4265E", "#86B42B", "#B3B42B",
                "#6A7EC8", "#8C6BC8", "#56ADBC", "#E3E3DD",
                "#666666", "#F92672", "#A6E22E", "#E2E22E",
                "#819AFF", "#AE81FF", "#66D9EF", "#F8F8F2",
            ]
        ),
        .init(
            id: "night-owl",
            title: "Night Owl",
            background: "#011627",
            foreground: "#D6DEEB",
            cursor: "#80A4C2",
            selectionBackground: "#093B5E",
            selectionForeground: "#D6DEEB",
            palette: [
                "#011627", "#EF5350", "#22DA6E", "#C5E478",
                "#82AAFF", "#C792EA", "#21C7A8", "#FFFFFF",
                "#575656", "#EF5350", "#22DA6E", "#FFEB95",
                "#82AAFF", "#C792EA", "#7FDBCA", "#FFFFFF",
            ]
        ),
        .init(
            id: "night-owl-light",
            title: "Night Owl Light",
            background: "#F6F6F6",
            foreground: "#403F53",
            cursor: "#90A7B2",
            selectionBackground: "#E0E0E0",
            selectionForeground: "#403F53",
            palette: [
                "#403F53", "#DE3D3B", "#08916A", "#E0AF02",
                "#288ED7", "#D6438A", "#2AA298", "#93A1A1",
                "#403F53", "#DE3D3B", "#08916A", "#DAAA01",
                "#288ED7", "#D6438A", "#2AA298", "#93A1A1",
            ]
        ),
        .init(
            id: "nord",
            title: "Nord",
            background: "#2E3440",
            foreground: "#D8DEE9",
            cursor: "#D8DEE9",
            selectionBackground: "#3F4758",
            selectionForeground: "#D8DEE9",
            palette: [
                "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B",
                "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
            ]
        ),
        .init(
            id: "one-dark-pro",
            title: "One Dark Pro",
            background: "#282C34",
            foreground: "#ABB2BF",
            cursor: "#528BFF",
            selectionBackground: "#41454E",
            selectionForeground: "#ABB2BF",
            palette: [
                "#3F4451", "#E05561", "#8CC265", "#D18F52",
                "#4AA5F0", "#C162DE", "#42B3C2", "#D7DAE0",
                "#4F5666", "#FF616E", "#A5E075", "#F0A45D",
                "#4DC4FF", "#DE73FF", "#4CD1E0", "#E6E6E6",
            ]
        ),
        .init(
            id: "rose-pine-moon",
            title: "Rosé Pine Moon",
            background: "#232136",
            foreground: "#E0DEF4",
            cursor: "#6E6A86",
            selectionBackground: "#312F45",
            selectionForeground: "#E0DEF4",
            palette: [
                "#393552", "#EB6F92", "#3E8FB0", "#F6C177",
                "#9CCFD8", "#C4A7E7", "#EA9A97", "#E0DEF4",
                "#908CAA", "#EB6F92", "#3E8FB0", "#F6C177",
                "#9CCFD8", "#C4A7E7", "#EA9A97", "#E0DEF4",
            ]
        ),
    ].sorted {
        $0.title.localizedStandardCompare($1.title) == .orderedAscending
    }

    static func preset(for storedValue: String) -> KookyTerminalTheme? {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNamespaced = trimmed.hasPrefix(bundledStoredValuePrefix)
        let id = isNamespaced
            ? String(trimmed.dropFirst(bundledStoredValuePrefix.count))
            : trimmed
        return presets.first { theme in
            theme.id == id || (!isNamespaced && theme.title == trimmed)
        }
    }

    static func availableThemes(userThemeDirectory: URL = ghosttyUserThemesDirectory()) -> [KookyTerminalTheme] {
        presets + userThemes(in: userThemeDirectory)
    }

    static func theme(for storedValue: String, in themes: [KookyTerminalTheme]) -> KookyTerminalTheme? {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(bundledStoredValuePrefix) {
            return themes.first { $0.isBundled && $0.storedValue == trimmed }
        }
        // Unprefixed values predate the bundled namespace and are also how
        // Ghostty persists user theme file names. Prefer a real user theme so
        // adding a bundled preset with the same name cannot change an existing
        // user's colors after an upgrade. Fall back to the old bundled id /
        // display-name aliases when no matching user file exists.
        if let userTheme = themes.first(where: {
            !$0.isBundled
                && ($0.id == trimmed || $0.title == trimmed || $0.storedValue == trimmed)
        }) {
            return userTheme
        }
        return themes.first {
            $0.isBundled && ($0.id == trimmed || $0.title == trimmed)
        }
    }

    static func ghosttyUserThemesDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("ghostty/themes", isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent(".config/ghostty/themes", isDirectory: true)
    }

    static func userThemes(in directory: URL) -> [KookyTerminalTheme] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }.compactMap { url -> KookyTerminalTheme? in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let values = parseGhosttyConfigLines(text)
            return KookyTerminalTheme(
                userThemeName: url.lastPathComponent,
                background: values["background"],
                foreground: values["foreground"],
                lines: text.split(whereSeparator: \.isNewline).map(String.init)
            )
        }
    }

    static func bundledStoredValue(for id: String) -> String {
        bundledStoredValuePrefix + id
    }

    private init(
        id: String,
        title: String,
        background: String,
        foreground: String,
        cursor: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String]
    ) {
        self.id = id
        self.title = title
        self.storedValue = Self.bundledStoredValue(for: id)
        self.backgroundHex = background
        self.foregroundHex = foreground
        self.source = .bundled
        self.lines = [
            "background = \(background)",
            "foreground = \(foreground)",
            "cursor-color = \(cursor)",
            "selection-background = \(selectionBackground)",
            "selection-foreground = \(selectionForeground)",
        ] + palette.enumerated().map { idx, color in
            "palette = \(idx)=\(color)"
        }
    }

    private init(userThemeName: String, background: String?, foreground: String?, lines: [String]) {
        self.id = "ghostty-user:\(userThemeName)"
        self.title = userThemeName
        self.storedValue = userThemeName
        self.backgroundHex = background ?? "#282C34"
        self.foregroundHex = foreground ?? "#EFEFF1"
        self.lines = lines
        self.source = .ghosttyUser
    }

    private static func parseGhosttyConfigLines(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = unwrapQuotes(rawValue)
        }
        return values
    }

    private static func unwrapQuotes(_ raw: String) -> String {
        guard raw.count >= 2,
              raw.first == raw.last,
              raw.first == "\"" || raw.first == "'" else { return raw }
        return String(raw.dropFirst().dropLast())
    }
}
