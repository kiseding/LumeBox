part of 'comic_reader_page.dart';

/// A light, legible control surface over either light or dark comic artwork.
class _ReaderGlass extends StatelessWidget {
  const _ReaderGlass(
    this.child, {
    this.radius = 28,
    this.opacity = .58,
    this.tint = Colors.white,
  });
  final Widget child;
  final double radius, opacity;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0D000000),
            blurRadius: 14,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ComicGlassBackdrop(
          radius: radius,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.lerp(
                    tint,
                    Colors.white,
                    .16,
                  )!.withValues(alpha: opacity + (1 - opacity) * .16),
                  tint.withValues(alpha: opacity),
                ],
              ),
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white.withValues(alpha: .85)),
            ),
            child: Theme(
              data: theme.copyWith(
                brightness: Brightness.light,
                colorScheme: const ColorScheme.light(primary: _readerAccent),
                dividerTheme: const DividerThemeData(
                  color: Color(0x19000000),
                  thickness: .7,
                ),
                iconButtonTheme: IconButtonThemeData(
                  style: ButtonStyle(
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.disabled)
                          ? const Color(0xFFABACB2)
                          : const Color(0xFF16171B),
                    ),
                  ),
                ),
                textButtonTheme: TextButtonThemeData(
                  style: TextButton.styleFrom(
                    foregroundColor: _readerAccent,
                    backgroundColor: Colors.white.withValues(alpha: .45),
                    shape: const StadiumBorder(
                      side: BorderSide(color: Color(0x22000000), width: .6),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                  ),
                ),
                sliderTheme: const SliderThemeData(
                  thumbShape: _ReaderSliderThumb(),
                  thumbColor: Colors.white,
                  trackHeight: 4,
                  activeTrackColor: _readerAccent,
                  inactiveTrackColor: Color(0x19000000),
                ),
                switchTheme: SwitchThemeData(
                  thumbColor: const WidgetStatePropertyAll(Colors.white),
                  trackColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.selected)
                        ? _readerAccent
                        : const Color(0xFFBFC1C5),
                  ),
                  trackOutlineColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  trackOutlineWidth: const WidgetStatePropertyAll(0),
                ),
                textTheme: theme.textTheme.apply(
                  bodyColor: const Color(0xFF16171B),
                  displayColor: const Color(0xFF16171B),
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: IconTheme(
                  data: const IconThemeData(color: Color(0xFF16171B), size: 23),
                  child: DefaultTextStyle(
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: const Color(0xFF16171B),
                      fontSize: 16,
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
