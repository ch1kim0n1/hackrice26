import Foundation
import UserNotifications

/// Local push notifications — the session-open engine. No backend needed:
/// two repeating daily reminders (morning quest + evening streak-at-risk)
/// that pull the player back in without them deciding to open the app.
enum NQNotifications {
    static let morningQuestId = "nq.reminder.morningQuest"
    static let streakRiskId = "nq.reminder.streakRisk"

    /// Requests permission (first call shows the system prompt) and schedules
    /// both repeating reminders. Safe to call repeatedly.
    static func enable() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            scheduleMorningQuest()
            scheduleStreakRisk()
        }
    }

    /// Morning nudge: "Your squad is waiting — scan today's food."
    private static func scheduleMorningQuest() {
        let content = UNMutableNotificationContent()
        content.title = "Your squad is waiting"
        content.body = "Scan today's food to keep your streak and boost your squad."
        content.sound = .default
        add(id: morningQuestId, content: content, hour: 9, minute: 0)
    }

    /// Evening loss-framing: the streak is about to break. This is the
    /// highest-leverage notification in the genre — fear of loss, not gain.
    private static func scheduleStreakRisk() {
        let content = UNMutableNotificationContent()
        content.title = "Your streak is in danger"
        content.body = "Scan one food before midnight or your streak resets to zero."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        add(id: streakRiskId, content: content, hour: 20, minute: 0)
    }

    private static func add(id: String, content: UNMutableNotificationContent, hour: Int, minute: Int) {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Called right after a successful scan — the streak is safe today, so
    /// tonight's loss-framing reminder is cancelled (and rescheduled for a
    /// day the streak is actually at risk).
    static func cancelStreakRiskForToday() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [streakRiskId])
        // Re-add for tomorrow evening so the repeating cycle continues.
        var components = DateComponents()
        components.hour = 20
        components.minute = 0
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        let day = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
        components.year = day.year
        components.month = day.month
        components.day = day.day
        let content = UNMutableNotificationContent()
        content.title = "Your streak is in danger"
        content.body = "Scan one food before midnight or your streak resets to zero."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: streakRiskId, content: content, trigger: trigger))
    }
}
