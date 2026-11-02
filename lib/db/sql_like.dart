/// LIKE 模式转义：让用户输入里的 `%`、`_`、`\` 按字面量匹配。
///
/// 原先 `filename LIKE '%$q%'` 会把 `_` 当成任意单字符、`%` 当成任意串。
/// 对文件名与标签名来说这两个字符是合法内容（`IMG_0001.jpg`、
/// `2024_06`、`a%b`），所以模式串必须先转义，并在 SQL 里带上
/// `ESCAPE '\'` 才能生效。
library;

/// SQL 里跟在参数占位符后的 ESCAPE 子句。
const String sqlLikeEscape = r"ESCAPE '\'";

/// 转义 LIKE 模式里的通配符。反斜杠必须最先处理，
/// 否则后面插入的转义反斜杠会被再转义一次。
String escapeLike(String raw) => raw
    .replaceAll('\\', r'\\')
    .replaceAll('%', r'\%')
    .replaceAll('_', r'\_');
