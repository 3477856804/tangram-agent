class FlaiRadius {
  final double sm;
  final double md;
  final double lg;
  final double xl;
  final double full;

  const FlaiRadius({
    this.sm = 4.0,
    this.md = 8.0,
    this.lg = 12.0,
    this.xl = 16.0,
    this.full = 9999.0,
  });

  FlaiRadius copyWith({
    double? sm,
    double? md,
    double? lg,
    double? xl,
    double? full,
  }) {
    return FlaiRadius(
      sm: sm ?? this.sm,
      md: md ?? this.md,
      lg: lg ?? this.lg,
      xl: xl ?? this.xl,
      full: full ?? this.full,
    );
  }
}
