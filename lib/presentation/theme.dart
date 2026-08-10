import 'package:flutter/material.dart';

/// A Material representation of the desktop Netcatty theme catalogue.
class NetcattyThemePreset {
  const NetcattyThemePreset({
    required this.id,
    required this.name,
    required this.brightness,
    required this.background,
    required this.foreground,
    required this.card,
    required this.primary,
    required this.border,
    required this.error,
  });

  final String id;
  final String name;
  final Brightness brightness;
  final Color background;
  final Color foreground;
  final Color card;
  final Color primary;
  final Color border;
  final Color error;
}

class NetcattyTheme {
  static const accent = Color(0xfff97316);

  static final List<NetcattyThemePreset> _catalogue =
      _rawThemes.trim().split('\n').map(_parsePreset).toList(growable: false);

  static List<NetcattyThemePreset> presets(Brightness brightness) => _catalogue
      .where((preset) => preset.brightness == brightness)
      .toList(growable: false);

  static NetcattyThemePreset resolve(Brightness brightness, String id) {
    final available = presets(brightness);
    return available.firstWhere(
      (preset) => preset.id == id,
      orElse: () => available.firstWhere(
        (preset) =>
            preset.id == (brightness == Brightness.dark ? 'midnight' : 'snow'),
        orElse: () => available.first,
      ),
    );
  }

  static ThemeData build(Brightness brightness, String id) {
    final preset = resolve(brightness, id);
    final dark = brightness == Brightness.dark;
    final seed = ColorScheme.fromSeed(
      seedColor: preset.primary,
      brightness: brightness,
    );
    final scheme = seed.copyWith(
      primary: preset.primary,
      onPrimary: _contrast(preset.primary),
      secondary: preset.primary,
      onSecondary: _contrast(preset.primary),
      surface: preset.card,
      onSurface: preset.foreground,
      outline: preset.border,
      outlineVariant: preset.border.withValues(alpha: 0.7),
      error: preset.error,
      onError: _contrast(preset.error),
    );
    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      scaffoldBackgroundColor: preset.background,
      colorScheme: scheme,
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: preset.card,
        indicatorColor: preset.primary.withValues(alpha: 0.2),
        height: 68,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: preset.background,
        foregroundColor: preset.foreground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: preset.card,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: preset.border),
        ),
      ),
      dividerColor: preset.border,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color.alphaBlend(
          preset.foreground.withValues(alpha: dark ? 0.025 : 0.018),
          preset.card,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: preset.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: preset.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: preset.background,
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: preset.card,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: preset.foreground,
        contentTextStyle: TextStyle(color: preset.background),
      ),
    );
  }

  static NetcattyThemePreset _parsePreset(String line) {
    final values = line.split('|');
    final brightness = values[0] == 'd' ? Brightness.dark : Brightness.light;
    return NetcattyThemePreset(
      id: values[1],
      name: values[2],
      brightness: brightness,
      background: _hsl(values[3]),
      foreground: _hsl(values[4]),
      card: _hsl(values[5]),
      primary: _hsl(values[6]),
      border: _hsl(values[7]),
      error: _hsl(values[8]),
    );
  }

  static Color _hsl(String value) {
    final parts = value.replaceAll('%', '').split(' ');
    return HSLColor.fromAHSL(
      1,
      double.parse(parts[0]),
      double.parse(parts[1]) / 100,
      double.parse(parts[2]) / 100,
    ).toColor();
  }

  static Color _contrast(Color color) =>
      color.computeLuminance() > 0.46 ? Colors.black : Colors.white;
}

// background, foreground, card, primary, border and destructive tokens are
// copied from the desktop catalogue. Keeping this compact makes all 124
// variants available without maintaining a parallel generated asset.
const _rawThemes = r'''
l|snow|Snow|216 33% 96%|222 47% 12%|0 0% 100%|208 100% 50%|220 16% 82%|0 70% 50%
l|pure-white|Pure White|0 0% 100%|222 47% 12%|0 0% 100%|210 90% 48%|220 12% 88%|0 70% 50%
l|ivory|Ivory|38 40% 95%|222 47% 12%|40 45% 98%|28 85% 50%|34 24% 84%|0 70% 50%
l|mist|Mist|210 20% 97%|222 47% 12%|210 20% 99%|195 90% 45%|210 14% 84%|0 70% 50%
l|mint|Mint|150 30% 96%|222 47% 12%|150 30% 98%|160 70% 40%|150 16% 84%|0 70% 50%
l|sand|Sand|34 30% 94%|222 47% 12%|34 30% 97%|24 80% 50%|34 16% 82%|0 70% 50%
l|lavender|Lavender|270 30% 97%|222 47% 12%|270 30% 99%|270 70% 55%|270 18% 86%|0 70% 50%
l|a-cup-of-coffee|A cup of coffee|0 0% 98.4%|0 0% 0%|0 0% 99.2%|211.3 95.3% 33.1%|0 0% 83.5%|0 61.4% 49.8%
l|abolkog|ABOLKOG|0 0% 100%|210 12.2% 16.1%|0 0% 100%|40 70.6% 73.3%|0 0% 85.1%|354.3 42.3% 56.5%
l|aurora|Aurora|44.5 88.6% 93.1%|40.5 100% 14.5%|47.1 87.5% 96.9%|171.4 100% 22%|43.8 24.5% 79.2%|341.7 100% 36.1%
l|ayu|Ayu|210 16.7% 97.6%|210 5.2% 38%|240 20% 99%|75.1 100% 35.1%|210 2.3% 83.1%|0 80.9% 69.2%
l|base16-flat|Base16 Flat|192 15.2% 93.5%|184.3 5.8% 52.5%|200 20% 97.1%|204.1 69.9% 53.1%|195 3.8% 79.6%|5.6 78.1% 57.1%
l|base16-mocha|Base16 Mocha|18 33.3% 94.1%|30 22% 32.2%|12 38.5% 97.5%|16.1 51.9% 63.3%|15 7.8% 80%|347.1 50.7% 58.6%
l|blue-dolphin|Blue Dolphin|195 40% 94.1%|193.2 65.8% 14.9%|192 38.5% 97.5%|195 100% 25.1%|192 9.8% 80%|353.3 64.3% 43.9%
l|calm-days-sober-nights-sky|Calm Days, Sober Nights Sky|0 0% 100%|221.5 11.1% 45.9%|0 0% 100%|142.1 100% 35.1%|0 0% 85.1%|350.1 76% 67.3%
l|catppuccin|Catppuccin|220 23.1% 94.9%|233.8 16% 35.5%|220 27.3% 97.8%|219.9 91.5% 53.9%|216 5.1% 80.6%|347.1 86.7% 44.1%
l|chai|Chai|0 0% 96.9%|228 8.2% 23.9%|0 0% 98.4%|262.9 85.6% 59.2%|0 0% 82.4%|344.9 69.7% 49.2%
l|chinolor|Chinolor|38.2 44% 95.1%|130 6.5% 18%|36 45.5% 97.8%|48.2 100% 23.9%|36 10.2% 80.8%|355.2 83.7% 59%
l|cyberdyne|Cyberdyne|248.6 22.6% 93.9%|153.9 69.7% 12.9%|255 28.6% 97.3%|213 100% 31.4%|240 5.9% 80%|9 76.9% 40.8%
l|desert|Desert|34.3 22.6% 93.9%|27.6 74.5% 20%|30 28.6% 97.3%|147.7 100% 20.4%|30 5.9% 80%|0 100% 36.1%
l|django-reborn-again|Django Reborn Again|150 26.7% 94.1%|155 47.4% 14.9%|150 28.6% 97.3%|51.1 100% 23.9%|150 5.9% 80%|20.9 100% 36.1%
l|espresso|Espresso|46.7 23.1% 92.4%|180 37.9% 17.1%|45 22.2% 96.5%|195.8 20.4% 36.5%|45 7.3% 78.4%|0 27.4% 48.6%
l|eyehealth|EyeHealth|47 100% 95.5%|22.4 31.2% 42.2%|48 100% 98%|35.8 100% 50%|48 20.8% 81.2%|354 67% 56.1%
l|flexoki|Flexoki|48 100% 97.1%|0 3.2% 6.1%|51.4 100% 98.6%|45.3 98.9% 34.1%|46.2 14.6% 82.5%|3.1 62% 42.4%
l|fox|Fox|30 30.8% 94.9%|263 35.3% 26.1%|30 33.3% 97.6%|28.9 97.7% 34.1%|34.3 7.1% 80.6%|354 65.8% 39%
l|garbage-oracle|Garbage Oracle|303.8 38.1% 91.8%|320.9 100% 26.5%|300 36.8% 96.3%|22.7 66.2% 29%|304.3 12.5% 78%|352.2 54.7% 41.6%
l|github|GitHub|0 0% 100%|213.3 12.7% 13.9%|0 0% 100%|212.4 92.1% 44.5%|0 0% 85.1%|355.8 71.8% 47.3%
l|gruvbox-material|Gruvbox Material|48.5 86.7% 88.2%|22.5 31.2% 30.2%|49.6 85.2% 94.7%|36.5 90.5% 37.1%|49.1 34.4% 74.9%|0 49% 52.4%
l|homebrew|Homebrew|120 40% 94.1%|120 65.8% 14.9%|120 38.5% 97.5%|300 100% 23.5%|120 9.8% 80%|0 100% 23.9%
l|ic-orange-ppl|IC Orange PPL|35 40% 94.1%|34.8 65.8% 14.9%|36 38.5% 97.5%|24 100% 23.5%|36 9.8% 80%|14.1 100% 26.7%
l|ikki|IKKI|43.6 100% 97.8%|22.4 31.2% 42.2%|48 100% 99%|35.8 100% 50%|42 11.6% 83.1%|354 67% 56.1%
l|kanso-ink|Kanso Ink|40 10.3% 94.3%|218.2 13.9% 15.5%|60 7.7% 97.5%|351.6 55.3% 51.8%|40 3% 80.2%|351.6 55.3% 51.8%
l|kary-pro-colors|Kary Pro Colors|207.3 57.9% 96.3%|209.5 53.8% 46.7%|204 55.6% 98.2%|32.7 76.5% 36.7%|206.7 9.7% 81.8%|13.1 69.6% 46.5%
l|light-purple|Light purple|10 15.8% 92.5%|274.8 33.8% 29%|20 17.6% 96.7%|46.8 98.2% 44.3%|12 4.6% 78.6%|0.7 71.2% 55.1%
l|mondrian|Mondrian|0 0% 100%|0 0% 0%|0 0% 100%|217.4 89% 60.8%|0 0% 85.1%|4.8 69.5% 53.7%
l|monochrome|Monochrome|210 40% 96.1%|222.2 47.4% 11.2%|200 33.3% 98.2%|222.2 47.4% 11.2%|214.3 7.5% 81.8%|222.2 47.4% 11.2%
l|monochrome-stone|Monochrome Stone|60 4.8% 95.9%|24 9.8% 10%|60 11.1% 98.2%|24 9.8% 10%|60 1.1% 81.4%|24 9.8% 10%
l|monokai-pro-spectrum|Monokai Pro Spectrum|28.2 54.8% 93.9%|289.1 13.6% 15.9%|30 57.1% 97.3%|34.8 96.7% 35.3%|28 14.6% 79.8%|341.8 57.9% 54.3%
l|monospace|Monospace|0 0% 100%|216.9 29.5% 17.3%|0 0% 100%|196.7 100% 31.8%|0 0% 85.1%|356.8 61.6% 52%
l|noctis-azureus|Noctis Azureus|40 90% 96.1%|186.8 100% 19%|40 100% 98.2%|203 100% 47.1%|40 16.1% 81.8%|15.1 78% 50%
l|noctis-hibernus|Noctis Hibernus|180 10% 96.1%|186.8 100% 19%|180 11.1% 98.2%|203 100% 47.1%|180 2.1% 81.6%|15.1 78% 50%
l|noir-essence|Noir Essence|41.5 44.8% 94.3%|0 0% 0%|48 38.5% 97.5%|54.1 100% 23.9%|43.6 10.9% 80.2%|3 56.6% 58.4%
l|nord-midnight|Nord Midnight|217.5 26.7% 94.1%|220 16.4% 21.6%|210 28.6% 97.3%|187.1 83% 30%|220 5.9% 80%|354.3 42.3% 56.5%
l|notionish|Notionish|0 0% 100%|60 2% 9.6%|0 0% 100%|208.4 100% 43.5%|0 0% 85.1%|7.2 83.8% 48.4%
l|phonebook|Phonebook|35.6 37.2% 83.1%|31.3 45.1% 20%|36 38.5% 92.4%|186.5 100% 37.8%|35.6 18.1% 70.8%|4 89.9% 61%
l|polychrome|Polychrome|30 20% 98%|255.6 60% 44.1%|60 20% 99%|255.3 86.5% 59.2%|60 1.2% 83.3%|0 90.2% 56.1%
l|purplepeter|Purplepeter|261.8 40.7% 94.7%|258.6 55.3% 14.9%|264 38.5% 97.5%|190.2 83.9% 31.6%|260 9.1% 80.6%|0 41.9% 48.6%
l|rainglow-codecourse|Rainglow Codecourse|0 0% 100%|197.7 26.6% 44.9%|0 0% 100%|202.7 97.4% 55.3%|0 0% 85.1%|348.8 86% 39.2%
l|rainglow-crisp|Rainglow Crisp|0 0% 100%|300 13.3% 11.8%|0 0% 100%|23 97.5% 52.4%|0 0% 85.1%|348.8 86% 39.2%
l|rainglow-lavender|Rainglow Lavender|0 0% 100%|275 15% 15.7%|0 0% 100%|273.9 100% 67.1%|0 0% 85.1%|348.8 86% 39.2%
l|remedy-tilted|Remedy Tilted|41.1 90.5% 95.9%|39.2 72% 19.6%|40 100% 98.2%|24.6 65.8% 62.2%|41.2 17% 81.6%|0 42.9% 45.3%
l|rose-pine|Rosé Pine|32.3 56.5% 95.5%|247.7 19.2% 39.8%|30 60% 98%|34.6 81.2% 56.1%|30 12.5% 81.2%|343 35.1% 54.7%
l|selene-selenized|Selene Selenized|41.7 94.7% 92.5%|193.8 18.8% 27.1%|42.4 100% 96.7%|207.1 100% 41.2%|42.6 28.4% 78.6%|356.6 73.1% 48%
l|soft-color|Soft Color|95 100% 97.6%|0 0% 35.3%|96 100% 99%|211.3 95.3% 33.1%|96 11.6% 83.1%|0 61.4% 49.8%
l|tearout|Tearout|96.9 26.5% 90.4%|90 7.9% 14.9%|100 27.3% 95.7%|22.5 36.4% 34.5%|92.7 9.2% 76.7%|6.7 33.3% 42.4%
l|tokyo-night|Tokyo Night|230 11.1% 89.4%|221.9 55.3% 48.2%|240 8.3% 95.3%|195.1 100% 29.6%|228 4.1% 75.9%|342.6 91% 56.3%
l|tomorrow-night-eighties|Tomorrow Night Eighties|0 0% 100%|60 0.7% 30%|0 0% 100%|71.6 100% 27.5%|0 0% 85.1%|359.6 66.7% 47.1%
l|vaporizer-turquoise|Vaporizer Turquoise|0 0% 95.3%|117.5 50% 18.8%|0 0% 98%|300 94.8% 37.8%|0 0% 81.2%|0 61.4% 49.8%
l|xotopio|Xotopio|20 15.8% 96.3%|0 0% 12.9%|60 11.1% 98.2%|331 64.2% 55.1%|20 3.2% 81.8%|0.7 71.2% 55.1%
l|yuttari|Yuttari|336.7 100% 96.5%|334.3 10.4% 26.3%|337.5 100% 98.4%|223.5 30.4% 60%|337.5 17.4% 82%|0 38.8% 54.5%
l|zenbones-rosebones|Zenbones Rosebones|32.7 57.9% 96.3%|2.4 27.4% 35.1%|36 55.6% 98.2%|34.4 83% 56.3%|33.3 9.7% 81.8%|343.2 35.7% 54.9%
l|zhxo-red|Zhxo'red|24 100% 97.1%|240 10.1% 51.6%|25.7 100% 98.6%|284.1 83.8% 45.9%|23.1 14.6% 82.5%|0 53.4% 50.4%
d|pure-black|Pure Black|0 0% 0%|0 0% 95%|0 0% 5%|210 90% 60%|0 0% 12%|0 70% 50%
d|midnight|Midnight|220 28% 10%|210 40% 95%|220 22% 12%|200 100% 61%|220 22% 18%|0 70% 50%
d|deep-blue|Deep Blue|220 35% 10%|210 40% 96%|220 28% 14%|210 90% 60%|220 20% 22%|0 70% 50%
d|vscode|VS Code|0 0% 12%|210 20% 92%|0 0% 16%|210 90% 60%|0 0% 22%|0 70% 50%
d|graphite|Graphite|220 8% 12%|210 20% 94%|220 8% 16%|210 80% 60%|220 6% 22%|0 70% 50%
d|obsidian|Obsidian|240 8% 8%|210 20% 94%|240 8% 12%|265 80% 65%|240 6% 20%|0 70% 50%
d|forest|Forest|150 12% 10%|150 20% 92%|150 12% 14%|160 70% 50%|150 8% 22%|0 70% 50%
d|a-cup-of-coffee|A cup of coffee|0 0% 11.8%|0 0% 74.5%|0 0% 15.7%|60 86.9% 48%|0 0% 29.4%|0 61.4% 49.8%
d|abolkog|ABOLKOG|220 13% 18%|218.8 27.9% 88%|223.6 9.9% 21.8%|40 70.6% 73.3%|222 5.7% 34.5%|354.3 42.3% 56.5%
d|aurora|Aurora|223.6 13.6% 15.9%|45.2 100% 57.8%|222 10% 19.6%|171.5 97.2% 42.5%|226.7 5.4% 32.7%|338.3 87.1% 54.5%
d|ayu|Ayu|222.4 21.5% 15.5%|48 8.9% 78%|221.3 16.3% 19.2%|271.3 95.9% 80.8%|221.5 7.9% 32.4%|6.1 83.1% 65.1%
d|base16-flat|Base16 Flat|210 29% 24.3%|0 0% 87.8%|209.1 24.8% 27.6%|168.1 75.7% 42%|209 14.4% 39.4%|5.6 78.1% 57.1%
d|base16-mocha|Base16 Mocha|31.6 19.2% 19.4%|12 9.6% 79.6%|30 15.3% 23.1%|16.1 51.9% 63.3%|32 8.3% 35.5%|347.1 50.7% 58.6%
d|blue-dolphin|Blue Dolphin|192.3 100% 25.9%|193.4 100% 88.6%|192.3 85.2% 29.2%|218.8 100% 83.3%|192.5 51% 40.8%|357.1 100% 75.5%
d|calm-days-sober-nights-sky|Calm Days, Sober Nights Sky|221.7 31.5% 14.3%|220 31.3% 86.9%|220.9 23.9% 18%|198 93.3% 70.6%|220 11.2% 31.4%|354 77.1% 69.2%
d|catppuccin|Catppuccin|229.1 18.6% 23.1%|227.2 70.1% 86.9%|228.6 15.6% 26.5%|316 73.2% 83.9%|226.7 9.2% 38.4%|358.8 67.8% 70.8%
d|chai|Chai|240 75% 1.6%|203.6 27.5% 80%|240 20% 5.9%|202.9 78.4% 60%|240 4.6% 21.4%|16.8 78.2% 55.1%
d|chinolor|Chinolor|130 6.5% 18%|36.9 19.4% 86.9%|120 4.5% 21.8%|44.4 92.4% 69%|132 2.9% 34.3%|355.2 83.7% 59%
d|cyberdyne|Cyberdyne|244.7 60% 16.7%|154.4 100% 50%|245 46.2% 20.4%|300.5 100% 78.2%|244.5 23.5% 33.3%|6.9 100% 72.5%
d|desert|Desert|0 0% 20%|0 0% 100%|0 0% 23.5%|35.9 100% 83.9%|0 0% 36.1%|0 100% 58.4%
d|django-reborn-again|Django Reborn Again|154.6 72.2% 7.1%|150 5.7% 86.3%|156 43.9% 11.2%|51.2 100% 69.2%|154.3 16% 25.7%|21.9 98.4% 51.4%
d|espresso|Espresso|18 20% 9.8%|33.3 29.5% 76.1%|13.3 12.7% 13.9%|42.9 70.9% 69%|15 5.6% 27.8%|8.6 70.9% 69%
d|eyehealth|EyeHealth|0 0% 25.9%|0 0% 100%|0 0% 29.4%|35.8 100% 50%|0 0% 40.8%|354 67% 56.1%
d|flexoki|Flexoki|0 3.2% 6.1%|54.5 10.1% 78.6%|0 1.9% 10.4%|45.2 81.7% 44.9%|0 0.8% 24.9%|5 61% 53.7%
d|fox|Fox|213.9 31.5% 14.3%|210 2% 80.8%|212.7 23.9% 18%|181.1 52.9% 60%|213.3 11.2% 31.4%|345.2 53% 54.9%
d|garbage-oracle|Garbage Oracle|311.5 31% 16.5%|303.8 38.1% 91.8%|312 24.3% 20.2%|124.3 95.4% 82.9%|311.4 12.4% 33.1%|359.4 92.8% 78.2%
d|github|GitHub|216 27.8% 7.1%|207.7 35.1% 92.7%|213.3 15.8% 11.2%|212 100% 67.3%|210 6.2% 25.5%|3.8 100% 72.4%
d|gruvbox-material|Gruvbox Material|0 1.2% 15.9%|38 41.1% 71.4%|0 1% 19.8%|3.1 76.4% 65.1%|0 0.6% 32.7%|3.1 76.4% 65.1%
d|homebrew|Homebrew|0 0% 0%|120 100% 50%|0 0% 4.3%|184 100% 34.9%|0 0% 20%|0 100% 30%
d|ic-orange-ppl|IC Orange PPL|0 0% 14.9%|34.8 100% 75.7%|0 0% 18.8%|36.2 100% 48.4%|0 0% 31.8%|17.7 100% 37.8%
d|ikki|IKKI|0 0% 32.5%|0 0% 83.9%|0 0% 35.7%|35.8 100% 50%|0 0% 45.9%|354 67% 56.1%
d|kanso-ink|Kanso Ink|220 18.4% 9.6%|150 3.6% 78%|225 11.4% 13.7%|41.4 33% 65.5%|222.9 5% 27.6%|4.2 42.2% 60%
d|kary-pro-colors|Kary Pro Colors|0 0% 10.2%|0 0% 80%|0 0% 14.1%|15.8 54.6% 62%|0 0% 28.2%|15.8 54.6% 62%
d|light-purple|Light purple|293.3 18% 19.6%|0 100% 94.5%|292.9 14.3% 23.3%|191.2 74.1% 77.3%|295.7 7.7% 35.7%|348 69.3% 60.4%
d|mondrian|Mondrian|240 27.8% 14.1%|0 0% 100%|240 20.9% 17.8%|186.5 100% 37.8%|240 10% 31.4%|4.6 81.2% 56.3%
d|monochrome|Monochrome|222.2 47.4% 11.2%|210 40% 96.1%|223.8 33.3% 15.3%|210 40% 96.1%|223.6 14.9% 29%|210 40% 96.1%
d|monochrome-stone|Monochrome Stone|24 9.8% 10%|60 4.8% 95.9%|24 7% 13.9%|60 4.8% 95.9%|30 2.8% 27.8%|60 4.8% 95.9%
d|monokai-pro-spectrum|Monokai Pro Spectrum|0 0% 13.3%|265.7 100% 97.3%|0 0% 17.3%|22.6 97.7% 65.9%|0 0% 30.6%|343 96.3% 68.4%
d|monospace|Monospace|216 30.3% 12.9%|214.3 22.6% 87.8%|216 23.3% 16.9%|227 100% 72%|213.8 10.4% 30.2%|359.2 90% 68.6%
d|noctis-azureus|Noctis Azureus|203.1 78.8% 12.9%|203.6 27.5% 80%|202.8 58.1% 16.9%|187.1 78.4% 60%|203.4 26.5% 30.4%|16.8 78.2% 55.1%
d|noctis-hibernus|Noctis Hibernus|246.9 25.5% 20%|249 19.6% 80%|247.2 20.7% 23.7%|187.1 78.4% 60%|248.6 11.5% 35.9%|16.8 78.2% 55.1%
d|noir-essence|Noir Essence|200 8.1% 7.3%|41.5 44.8% 94.3%|200 5.1% 11.6%|23.5 76.1% 60.6%|210 1.5% 25.9%|3.1 76.4% 65.1%
d|nord-midnight|Nord Midnight|220 14.8% 12%|218.8 27.9% 88%|220 11.1% 15.9%|40 70.6% 73.3%|222.9 4.6% 29.6%|354.3 42.3% 56.5%
d|notionish|Notionish|60 2% 9.6%|30 10% 96.1%|60 1.4% 13.5%|39.9 100% 68.4%|60 0.7% 27.6%|6.9 90.2% 67.8%
d|phonebook|Phonebook|27.3 14.3% 15.1%|43 71.4% 67.1%|30 10.4% 18.8%|186.5 100% 37.8%|26.7 5.5% 32%|4 89.9% 61%
d|polychrome|Polychrome|250.9 12.1% 17.8%|251.7 31.6% 77.6%|252 9.1% 21.6%|47.7 100% 76.1%|253.3 5.1% 34.3%|9.1 100% 63.9%
d|purplepeter|Purplepeter|260 48% 19.6%|255.8 65.5% 94.3%|260.9 39% 23.1%|264 100% 77.5%|260.5 20.9% 35.7%|4.9 100% 71.4%
d|rainglow-codecourse|Rainglow Codecourse|204 33.3% 2.9%|197.6 30.4% 78%|204 13.5% 7.3%|202.7 97.4% 55.3%|210 3.5% 22.4%|348.8 86% 39.2%
d|rainglow-crisp|Rainglow Crisp|300 14.3% 4.1%|0 0% 100%|300 7% 8.4%|23 97.5% 52.4%|300 2.5% 23.3%|348.8 86% 39.2%
d|rainglow-lavender|Rainglow Lavender|270 12.5% 3.1%|274.8 46.3% 86.9%|270 5.3% 7.5%|273.9 100% 67.1%|240 0.9% 22.5%|348.8 86% 39.2%
d|remedy-tilted|Remedy Tilted|5 10.5% 22.4%|39.4 80.7% 83.7%|5 9.1% 25.9%|24.6 65.8% 62.2%|6.7 4.7% 37.8%|0 42.9% 45.3%
d|rose-pine|Rosé Pine|249.2 22% 11.6%|245.5 50% 91.4%|249.2 16.5% 15.5%|35 87.6% 71.6%|250.9 7.4% 29.2%|343.1 75.6% 67.8%
d|selene-selenized|Selene Selenized|189.9 87% 15.1%|183.8 17% 81.6%|189.4 66.7% 18.8%|203.3 100% 48%|190 32.9% 32.2%|2.7 97.8% 64.9%
d|soft-color|Soft Color|0 0% 14.5%|151.2 100% 95.1%|0 0% 18.4%|60 86.9% 48%|0 0% 31.8%|0 61.4% 49.8%
d|tearout|Tearout|85 11.8% 20%|30.9 76.1% 82%|85 10% 23.5%|46.4 51.2% 67.8%|84 5.4% 36.1%|20 44.3% 64.1%
d|tokyo-night|Tokyo Night|235 18.8% 12.5%|228.7 72.6% 85.7%|235 14.3% 16.5%|202.2 100% 74.5%|233.3 5.9% 30%|348.8 89% 71.6%
d|tomorrow-night-eighties|Tomorrow Night Eighties|0 0% 17.6%|0 0% 80%|0 0% 21.2%|40 100% 70%|0 0% 34.1%|358.5 82.6% 70.8%
d|vaporizer-turquoise|Vaporizer Turquoise|0 0% 9.8%|110.8 31.7% 67.8%|0 0% 13.7%|151.9 100% 36.9%|0 0% 27.8%|0 61.4% 49.8%
d|xotopio|Xotopio|233.3 69.2% 5.1%|0 0% 100%|232.9 36.2% 9.2%|195.1 100% 66.5%|232 12.2% 24.1%|327.7 100% 48.8%
d|yuttari|Yuttari|320 11.1% 10.6%|336.7 100% 96.5%|320 8.1% 14.5%|38.5 43.3% 64.7%|324 3.4% 28.4%|0 41.1% 58%
d|zenbones-rosebones|Zenbones Rosebones|249.2 21.3% 12%|0 17.8% 85.7%|249.2 16% 15.9%|35.1 87.8% 71%|250.9 7.3% 29.6%|343.3 75.3% 68.2%
d|zhxo-red|Zhxo'red|240 5.5% 10.8%|0 0% 67.1%|240 4% 14.7%|182.7 86% 44.9%|240 1.4% 28.6%|0 72.6% 55.7%
''';
