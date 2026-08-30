import { Metadata } from "./metadata"

export enum Frequenzy {
  Daily = "daily",
  Weekly = "weekly",
  Monthly = "monthly",
  Yearly = "yearly",
}

export interface RRuleOptions {
  freq: Frequenzy;
  interval: number;
  count?: number;
  until?: number;
  bysetpos?: number[];
  byweekday?: number[];
  bymonthday?: number[];
  bymonth?: number[];
  byyearday?: number[];
  byweekno?: number[];
}

export interface CalendarEvent {
  id: string;
  startTs: number;
  duration: number;
  /** Overrides the calendar's timezone for this event's recurrence, if set. */
  timezone?: string;
  busy: boolean;
  updated: number;
  created: number;
  exdates: number[];
  calendarId: string;
  userId: string;
  metadata: Metadata;
  recurrence?: RRuleOptions;
  reminder?: {
    minutesBefore: number;
  }
}

export interface CalendarEventInstance {
  startTs: number;
  endTs: number;
  busy: boolean;
}
