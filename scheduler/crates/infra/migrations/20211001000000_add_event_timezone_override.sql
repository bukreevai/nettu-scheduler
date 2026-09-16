-- Add optional per-event recurrence timezone override.
-- NULL preserves legacy behavior: Calendar.settings.timezone is used.
ALTER TABLE calendar_events
    ADD COLUMN timezone TEXT NULL;
