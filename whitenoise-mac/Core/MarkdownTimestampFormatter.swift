import Foundation
import MarmotKit

/// Renders MDK's `<t:UNIX_SECONDS:STYLE>` Markdown timestamps (MarmotKit 0.13) with the app's
/// selected language and the device's time zone. MDK carries only the instant and style; the
/// formatted text is presentation state, so a message built before a locale, time zone or clock
/// change keeps the text it was built with, and `relative` reads as of build time.
nonisolated enum MarkdownTimestampFormatter {
    /// Year 9999's last second. Anything outside ±this has no useful calendar rendering, so it
    /// shows the raw number instead.
    static let maxRenderableSeconds: Int64 = 253_402_300_799

    static func text(
        unixSeconds: Int64,
        style: MarkdownTimestampStyleFfi,
        now: Date = Date(),
        locale: Locale = AppLanguage.currentLocale,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard unixSeconds.magnitude <= UInt64(maxRenderableSeconds) else { return String(unixSeconds) }
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = timeZone

        var format: Date.FormatStyle
        switch style {
        case .shortTime:
            format = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        case .longTime:
            format = Date.FormatStyle(date: .omitted, time: .standard, locale: locale, calendar: calendar)
        case .shortDate:
            format = Date.FormatStyle(date: .numeric, time: .omitted, locale: locale, calendar: calendar)
        case .longDate:
            format = Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar)
        case .shortDateTime:
            format = Date.FormatStyle(date: .long, time: .shortened, locale: locale, calendar: calendar)
        case .longDateTime:
            format = Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar)
        case .compactDateTime:
            format = Date.FormatStyle(date: .numeric, time: .shortened, locale: locale, calendar: calendar)
        case .compactDateTimeSeconds:
            format = Date.FormatStyle(date: .numeric, time: .standard, locale: locale, calendar: calendar)
        case .relative:
            let relative = RelativeDateTimeFormatter()
            relative.locale = locale
            relative.calendar = calendar
            relative.unitsStyle = .full
            relative.dateTimeStyle = .named
            relative.formattingContext = .middleOfSentence
            return relative.localizedString(for: date, relativeTo: now)
        }
        format.timeZone = timeZone
        return format.format(date)
    }
}
