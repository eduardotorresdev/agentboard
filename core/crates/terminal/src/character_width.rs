use crate::unicode_tables::WIDTHS;

/// The entry of a sorted `(first, last, value)` table that holds `value`.
pub(crate) fn lookup(table: &[(u32, u32, u8)], value: u32) -> Option<u8> {
    let index = table.partition_point(|range| range.1 < value);
    table.get(index).filter(|range| range.0 <= value).map(|range| range.2)
}

/// Column width of a Unicode scalar, matching what terminal programs assume (wcwidth with
/// East Asian Wide/Fullwidth and emoji presentation as two columns). TUIs lay out text with
/// their own copy of these rules, so disagreeing here shifts everything after the character.
///
/// 0 for marks and joiners (they combine with the previous cell), 1 or 2 otherwise.
///
/// Swift computes this from its standard library's general categories and emoji property;
/// the table here is that function's answer for every code point, so both sides agree
/// whatever Unicode version either was built with.
pub(crate) fn of(value: u32) -> usize {
    if value < 0x300 {
        return if value >= 0xA0 || (0x20..0x7F).contains(&value) { 1 } else { 0 };
    }
    lookup(&WIDTHS, value).unwrap_or(1) as usize
}
