use chrono::Weekday;
use nettu_scheduler_domain::{CalendarEvent, CalendarSettings, RRuleFrequency, RRuleOptions, WeekDay};

// 2024-01-01T23:00:00Z is a Monday in UTC, but already Tuesday
// (2024-01-02T13:00 local) in Pacific/Kiritimati (UTC+14, no DST). A weekly
// rule restricted to Tuesdays therefore expands very differently depending
// on which timezone's calendar it is evaluated against.
const START_TS: i64 = 1_704_150_000_000;

fn settings_with_tz(tz: chrono_tz::Tz) -> CalendarSettings {
    CalendarSettings {
        timezone: tz,
        week_start: Weekday::Mon,
    }
}

fn weekly_tuesdays() -> RRuleOptions {
    RRuleOptions {
        freq: RRuleFrequency::Weekly,
        interval: 1,
        byweekday: Some(vec![WeekDay::new(Weekday::Tue)]),
        count: Some(3),
        ..Default::default()
    }
}

fn build_event(timezone: Option<chrono_tz::Tz>) -> CalendarEvent {
    CalendarEvent {
        start_ts: START_TS,
        duration: 1000 * 60 * 30,
        timezone,
        recurrence: Some(weekly_tuesdays()),
        ..Default::default()
    }
}

/// Calendar timezone = UTC, Event has no override => original
/// calendar-driven behavior is preserved.
#[test]
fn no_override_uses_calendar_timezone() {
    let calendar_settings = settings_with_tz(chrono_tz::UTC);
    let event = build_event(None);

    let with_none = event.expand(None, &calendar_settings);

    let mut equivalent_event = event.clone();
    equivalent_event.timezone = Some(chrono_tz::UTC);
    let with_explicit_calendar_tz = equivalent_event.expand(None, &calendar_settings);

    assert_eq!(with_none.len(), 3);
    assert_eq!(
        with_none.iter().map(|o| o.start_ts).collect::<Vec<_>>(),
        with_explicit_calendar_tz
            .iter()
            .map(|o| o.start_ts)
            .collect::<Vec<_>>()
    );
}

/// Calendar has one timezone, Event overrides with another => expansion
/// follows the Event's timezone, not the Calendar's.
#[test]
fn event_timezone_overrides_calendar_timezone() {
    let calendar_settings = settings_with_tz(chrono_tz::UTC);

    let without_override = build_event(None).expand(None, &calendar_settings);
    let with_override =
        build_event(Some(chrono_tz::Tz::Pacific__Kiritimati)).expand(None, &calendar_settings);

    // The override must change the result: same rule, same calendar, but a
    // different effective timezone yields a different expansion.
    assert_ne!(
        without_override.iter().map(|o| o.start_ts).collect::<Vec<_>>(),
        with_override.iter().map(|o| o.start_ts).collect::<Vec<_>>()
    );

    // The overridden event must match what the *calendar itself* would have
    // produced had it been configured with the event's timezone directly -
    // i.e. the event's timezone, not the calendar's, drives the expansion.
    let reference_calendar_settings = settings_with_tz(chrono_tz::Tz::Pacific__Kiritimati);
    let reference = build_event(None).expand(None, &reference_calendar_settings);

    assert_eq!(
        with_override.iter().map(|o| o.start_ts).collect::<Vec<_>>(),
        reference.iter().map(|o| o.start_ts).collect::<Vec<_>>()
    );

    // Sanity-check the concrete instants: interpreted in UTC, DTSTART
    // (Monday) doesn't satisfy BYWEEKDAY=Tue, so the first occurrence is
    // pushed to the next day; interpreted in Kiritimati, DTSTART is already
    // a Tuesday, so it is included as-is.
    assert_eq!(without_override[0].start_ts, START_TS + 1000 * 60 * 60 * 24);
    assert_eq!(with_override[0].start_ts, START_TS);
}

/// An explicit Event timezone equal to the Calendar's timezone must behave
/// exactly like no override at all.
#[test]
fn event_timezone_matching_calendar_is_a_no_op() {
    let calendar_settings = settings_with_tz(chrono_tz::UTC);

    let without_override = build_event(None).expand(None, &calendar_settings);
    let with_matching_override = build_event(Some(chrono_tz::UTC)).expand(None, &calendar_settings);

    assert_eq!(
        without_override.iter().map(|o| o.start_ts).collect::<Vec<_>>(),
        with_matching_override
            .iter()
            .map(|o| o.start_ts)
            .collect::<Vec<_>>()
    );
}
