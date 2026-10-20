import 'dart:convert';

/// Single-file ESM/CommonJS modules. Source spans are tokenized before rewriting
/// exports: text in comments, strings and template literals is never replaced.
class ModuleScript {
  static String wrap(String script) {
    final tokens = _tokens(script);
    final edits = <({int start, int end, String text})>[];
    final names = <String>[];
    var depth = 0;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (depth == 0 && token.value == 'import') {
        throw const FormatException('模块须是单文件；请先将 import 依赖打包进 .mjs / .js 文件');
      }
      if (depth == 0 && token.value == 'export') {
        final next = tokens.elementAtOrNull(i + 1);
        if (next?.value == 'default') {
          edits.add((
            start: token.start,
            end: next!.end,
            text: 'module.exports.default =',
          ));
        } else if (next?.value == '{') {
          var j = i + 2;
          final bindings = <String>[];
          while (j < tokens.length && tokens[j].value != '}') {
            final local = tokens[j++].value;
            if (local == ',') continue;
            var exported = local;
            if (tokens.elementAtOrNull(j)?.value == 'as') {
              j++;
              exported = tokens[j++].value;
            }
            if (!_identifier(local) || !_identifier(exported)) {
              throw const FormatException('模块 export 列表格式不支持');
            }
            bindings.add('exports[${jsonEncode(exported)}] = $local;');
          }
          if (j == tokens.length ||
              tokens.elementAtOrNull(j + 1)?.value == 'from') {
            throw const FormatException('模块不能从其他文件重新导出；请先打包依赖');
          }
          edits.add((
            start: token.start,
            end: tokens[j].end,
            text: bindings.join('\n'),
          ));
          i = j;
          continue;
        } else {
          var declaration = i + 1;
          if (tokens.elementAtOrNull(declaration)?.value == 'async') {
            declaration++;
          }
          final keyword = tokens.elementAtOrNull(declaration)?.value;
          final name = tokens.elementAtOrNull(declaration + 1)?.value;
          if (!['function', 'class', 'const', 'let', 'var'].contains(keyword) ||
              name == null ||
              !_identifier(name)) {
            throw const FormatException(
              '模块 export 写法不支持；请使用 export default 对象',
            );
          }
          // Multiple variable bindings and destructuring are deliberately rejected.
          if (['const', 'let', 'var'].contains(keyword)) {
            var nesting = 0;
            for (var j = declaration + 2; j < tokens.length; j++) {
              final value = tokens[j].value;
              if (nesting == 0 && value == ';') break;
              if (nesting == 0 && value == ',') {
                throw const FormatException('请将模块 export 的多个变量拆成独立声明');
              }
              if (['(', '[', '{'].contains(value)) nesting++;
              if ([')', ']', '}'].contains(value)) nesting--;
            }
          }
          names.add(name);
          edits.add((start: token.start, end: token.end, text: ''));
        }
      }
      if (token.value == '{') depth++;
      if (token.value == '}') depth--;
    }
    var body = script;
    for (final edit in edits.reversed) {
      body = body.replaceRange(edit.start, edit.end, edit.text);
    }
    return '''
(function () {
  var module = {exports: {}};
  var exports = module.exports;
  (function (module, exports) {
$body
${names.map((name) => 'exports[${jsonEncode(name)}] = $name;').join('\n')}
  })(module, exports);
  var source = module.exports.default || module.exports;
  if (!source || typeof source !== 'object') throw new Error('模块须导出源对象');
  if (!Object.keys(source).length) throw new Error('模块没有导出源接口');
  LumeSource = source;
})();
''';
  }

  static bool _identifier(String value) =>
      RegExp(r'^[A-Za-z_$][\w$]*$').hasMatch(value);

  static List<({String value, int start, int end})> _tokens(String text) {
    final result = <({String value, int start, int end})>[];
    var i = 0;
    String? previous;
    while (i < text.length) {
      final c = text[i];
      if (RegExp(r'\s').hasMatch(c)) {
        i++;
        continue;
      }
      if (text.startsWith('//', i)) {
        final end = text.indexOf('\n', i + 2);
        i = end < 0 ? text.length : end + 1;
        continue;
      }
      if (text.startsWith('/*', i)) {
        final end = text.indexOf('*/', i + 2);
        if (end < 0) throw const FormatException('模块注释未闭合');
        i = end + 2;
        continue;
      }
      final start = i;
      if (c == '"' || c == "'" || c == '`') {
        i++;
        while (i < text.length) {
          if (text[i] == r'\') {
            i += 2;
            continue;
          }
          if (text[i++] == c) break;
        }
        result.add((value: '<literal>', start: start, end: i));
        previous = '<literal>';
        continue;
      }
      if (c == '/' &&
          (previous == null ||
              [
                '=',
                '(',
                '[',
                ',',
                ':',
                'return',
                '=>',
                '!',
                '?',
              ].contains(previous))) {
        i++;
        var characterClass = false;
        while (i < text.length) {
          if (text[i] == r'\') {
            i += 2;
            continue;
          }
          if (text[i] == '[') characterClass = true;
          if (text[i] == ']') characterClass = false;
          if (text[i++] == '/' && !characterClass) break;
        }
        while (i < text.length && RegExp(r'[A-Za-z]').hasMatch(text[i])) {
          i++;
        }
        previous = '<literal>';
        result.add((value: previous, start: start, end: i));
        continue;
      }
      if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
        i++;
        while (i < text.length && RegExp(r'[\w$]').hasMatch(text[i])) {
          i++;
        }
      } else {
        i++;
      }
      previous = text.substring(start, i);
      result.add((value: previous, start: start, end: i));
    }
    return result;
  }
}
