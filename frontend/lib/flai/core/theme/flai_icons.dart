import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

class FlaiIconData {
  final IconData toolCall;

  final IconData thinking;

  final IconData citation;

  final IconData image;

  final IconData brokenImage;

  final IconData code;

  final IconData copy;

  final IconData check;

  final IconData close;

  final IconData send;

  final IconData attach;

  final IconData search;

  final IconData delete;

  final IconData add;

  final IconData expand;

  final IconData collapse;

  final IconData chat;

  final IconData model;

  final IconData refresh;

  final IconData error;

  const FlaiIconData({
    required this.toolCall,
    required this.thinking,
    required this.citation,
    required this.image,
    required this.brokenImage,
    required this.code,
    required this.copy,
    required this.check,
    required this.close,
    required this.send,
    required this.attach,
    required this.search,
    required this.delete,
    required this.add,
    required this.expand,
    required this.collapse,
    required this.chat,
    required this.model,
    required this.refresh,
    required this.error,
  });

  factory FlaiIconData.material() => const FlaiIconData(
        toolCall: Icons.build_rounded,
        thinking: Icons.psychology_rounded,
        citation: Icons.format_quote_rounded,
        image: Icons.image_rounded,
        brokenImage: Icons.broken_image_rounded,
        code: Icons.code_rounded,
        copy: Icons.content_copy_rounded,
        check: Icons.check_rounded,
        close: Icons.close_rounded,
        send: Icons.send_rounded,
        attach: Icons.attach_file_rounded,
        search: Icons.search_rounded,
        delete: Icons.delete_rounded,
        add: Icons.add_rounded,
        expand: Icons.expand_more_rounded,
        collapse: Icons.expand_less_rounded,
        chat: Icons.chat_bubble_outline_rounded,
        model: Icons.smart_toy_rounded,
        refresh: Icons.refresh_rounded,
        error: Icons.error_outline_rounded,
      );

  factory FlaiIconData.cupertino() => const FlaiIconData(
        toolCall: CupertinoIcons.wrench,
        thinking: CupertinoIcons.lightbulb,
        citation: CupertinoIcons.quote_bubble,
        image: CupertinoIcons.photo,
        brokenImage: CupertinoIcons.exclamationmark_triangle,
        code: CupertinoIcons.chevron_left_slash_chevron_right,
        copy: CupertinoIcons.doc_on_doc,
        check: CupertinoIcons.check_mark,
        close: CupertinoIcons.xmark,
        send: CupertinoIcons.arrow_up_circle_fill,
        attach: CupertinoIcons.paperclip,
        search: CupertinoIcons.search,
        delete: CupertinoIcons.trash,
        add: CupertinoIcons.plus,
        expand: CupertinoIcons.chevron_down,
        collapse: CupertinoIcons.chevron_up,
        chat: CupertinoIcons.chat_bubble_2,
        model: CupertinoIcons.desktopcomputer,
        refresh: CupertinoIcons.arrow_clockwise,
        error: CupertinoIcons.exclamationmark_circle,
      );

  factory FlaiIconData.sharp() => const FlaiIconData(
        toolCall: Icons.build_sharp,
        thinking: Icons.psychology_sharp,
        citation: Icons.format_quote_sharp,
        image: Icons.image_sharp,
        brokenImage: Icons.broken_image_sharp,
        code: Icons.code_sharp,
        copy: Icons.content_copy_sharp,
        check: Icons.check_sharp,
        close: Icons.close_sharp,
        send: Icons.send_sharp,
        attach: Icons.attach_file_sharp,
        search: Icons.search_sharp,
        delete: Icons.delete_sharp,
        add: Icons.add_sharp,
        expand: Icons.expand_more_sharp,
        collapse: Icons.expand_less_sharp,
        chat: Icons.chat_bubble_outline_sharp,
        model: Icons.smart_toy_sharp,
        refresh: Icons.refresh_sharp,
        error: Icons.error_outline_sharp,
      );

  FlaiIconData copyWith({
    IconData? toolCall,
    IconData? thinking,
    IconData? citation,
    IconData? image,
    IconData? brokenImage,
    IconData? code,
    IconData? copy,
    IconData? check,
    IconData? close,
    IconData? send,
    IconData? attach,
    IconData? search,
    IconData? delete,
    IconData? add,
    IconData? expand,
    IconData? collapse,
    IconData? chat,
    IconData? model,
    IconData? refresh,
    IconData? error,
  }) {
    return FlaiIconData(
      toolCall: toolCall ?? this.toolCall,
      thinking: thinking ?? this.thinking,
      citation: citation ?? this.citation,
      image: image ?? this.image,
      brokenImage: brokenImage ?? this.brokenImage,
      code: code ?? this.code,
      copy: copy ?? this.copy,
      check: check ?? this.check,
      close: close ?? this.close,
      send: send ?? this.send,
      attach: attach ?? this.attach,
      search: search ?? this.search,
      delete: delete ?? this.delete,
      add: add ?? this.add,
      expand: expand ?? this.expand,
      collapse: collapse ?? this.collapse,
      chat: chat ?? this.chat,
      model: model ?? this.model,
      refresh: refresh ?? this.refresh,
      error: error ?? this.error,
    );
  }
}
