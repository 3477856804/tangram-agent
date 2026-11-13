import 'package:flutter/material.dart';

class FlaiTypography {
  final String? fontFamily;
  final String? monoFontFamily;
  final double smSize;
  final double baseSize;
  final double lgSize;
  final double xlSize;
  final double xxlSize;
  final FontWeight regular;
  final FontWeight medium;
  final FontWeight semiBold;
  final FontWeight bold;

  const FlaiTypography({
    this.fontFamily,
    this.monoFontFamily,
    this.smSize = 13.0,
    this.baseSize = 14.0,
    this.lgSize = 17.0,
    this.xlSize = 20.0,
    this.xxlSize = 24.0,
    this.regular = FontWeight.w400,
    this.medium = FontWeight.w500,
    this.semiBold = FontWeight.w600,
    this.bold = FontWeight.w700,
  });


  TextStyle get sm => TextStyle(
        fontFamily: fontFamily,
        fontSize: smSize,
        fontWeight: regular,
      );

  TextStyle get base => TextStyle(
        fontFamily: fontFamily,
        fontSize: baseSize,
        fontWeight: regular,
      );

  TextStyle get lg => TextStyle(
        fontFamily: fontFamily,
        fontSize: lgSize,
        fontWeight: regular,
      );

  TextStyle get xl => TextStyle(
        fontFamily: fontFamily,
        fontSize: xlSize,
        fontWeight: semiBold,
      );

  TextStyle get xxl => TextStyle(
        fontFamily: fontFamily,
        fontSize: xxlSize,
        fontWeight: bold,
      );


  TextStyle bodySmall({Color? color}) => TextStyle(
        fontFamily: fontFamily,
        fontSize: smSize,
        fontWeight: regular,
        color: color,
      );

  TextStyle bodyBase({Color? color}) => TextStyle(
        fontFamily: fontFamily,
        fontSize: baseSize,
        fontWeight: regular,
        color: color,
      );

  TextStyle bodyLarge({Color? color}) => TextStyle(
        fontFamily: fontFamily,
        fontSize: lgSize,
        fontWeight: regular,
        color: color,
      );

  TextStyle heading({Color? color}) => TextStyle(
        fontFamily: fontFamily,
        fontSize: xlSize,
        fontWeight: semiBold,
        color: color,
      );

  TextStyle headingLarge({Color? color}) => TextStyle(
        fontFamily: fontFamily,
        fontSize: xxlSize,
        fontWeight: bold,
        color: color,
      );

  TextStyle mono({Color? color, double? fontSize}) => TextStyle(
        fontFamily: monoFontFamily,
        fontSize: fontSize ?? smSize,
        fontWeight: regular,
        color: color,
      );

  FlaiTypography copyWith({
    String? fontFamily,
    String? monoFontFamily,
    double? smSize,
    double? baseSize,
    double? lgSize,
    double? xlSize,
    double? xxlSize,
    FontWeight? regular,
    FontWeight? medium,
    FontWeight? semiBold,
    FontWeight? bold,
  }) {
    return FlaiTypography(
      fontFamily: fontFamily ?? this.fontFamily,
      monoFontFamily: monoFontFamily ?? this.monoFontFamily,
      smSize: smSize ?? this.smSize,
      baseSize: baseSize ?? this.baseSize,
      lgSize: lgSize ?? this.lgSize,
      xlSize: xlSize ?? this.xlSize,
      xxlSize: xxlSize ?? this.xxlSize,
      regular: regular ?? this.regular,
      medium: medium ?? this.medium,
      semiBold: semiBold ?? this.semiBold,
      bold: bold ?? this.bold,
    );
  }
}
