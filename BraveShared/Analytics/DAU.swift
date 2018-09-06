/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import XCGLogger

private let log = Logger.browserLogger

// Unit tests for DAU are located in brave/tests_src/unit/DauTest.swift.
public class DAU {

    /// Default installation date for legacy woi version.
    public static let defaultWoiDate = "2016-01-04"
    
    /// Number of seconds that determins when a user is "active"
    private let activeUserDuration = 10.0
    
    let prefs: Prefs
    
    private var launchTimer: Timer?
    private let baseUrl = "https://laptop-updates.brave.com/1/usage/ios?platform=ios"
    
    private let today: Date
    private var todayComponents: DateComponents {
        return (Calendar.current as NSCalendar).components([.day, .month , .year, .weekday], from: today)
    }
    
    public init(prefs: Prefs, date: Date? = nil) {
        self.prefs = prefs
        today = date ?? Date()
    }
    
    public func sendPingToServer() {
        if launchTimer != nil { return }
        launchTimer = Timer.scheduledTimer(timeInterval: activeUserDuration, target: self, selector: #selector(sendPingToServerInternal), userInfo: nil, repeats: false)
    }
    
    @objc public func sendPingToServerInternal() {
        guard let params = paramsAndPrefsSetup() else {
            log.debug("dau, no changes detected, no server ping")
            return
        }
        
        // Sending ping to server
        let fullUrl = baseUrl + params
        log.debug("send ping to server, url: \(fullUrl)")
        
        guard let url = URL(string: fullUrl) else {
            log.error("Stats failed to update, via invalud URL: \(fullUrl)")
            return
        }
        
        let task = URLSession.shared.dataTask(with: url) { _, _, error in
            if let e = error { log.error("status update error: \(e)") }
        }
        
        task.resume()
    }
    
    
    /** Return params query or nil if no ping should be send to server. */
    func paramsAndPrefsSetup() -> String? {
        let dauStats = Preferences.DAU.lastLaunchInfo.value
        
        /// This is not the same as `firstLaunch` concept, due to DAU delay, this may var be `true` on a subsequent launch
        let firstPing = dauStats == nil
        var params = channelParam + versionParam
        
        // All installs prior to this key existing (e.g. intallWeek == unknown) were set to `defaultWoiDate`
        // Enough time has passed where accounting for installs prior to this DAU improvement is unnecessary
        
        // See `woi` logic elsewhere to see fallback is handled
        
        // This could lead to an upgraded device having no `woi`, and that's fine
        if firstPing {
            Preferences.DAU.weekOfInstallation.value = todayComponents.weeksMonday
        }
        
        guard let dauStatParams = dauStatParams(dauStats, firstPing: firstPing) else {
            log.debug("dau, no changes detected, no server ping")
            return nil
        }
        
        params
            += dauStatParams
            + firstLaunchParam(firstPing)
            // Must be after setting up the preferences
            + weekOfInstallationParam

        // TODO: #190 goes here
        
        let secsMonthYear = [Int(today.timeIntervalSince1970), todayComponents.month, todayComponents.year]
        Preferences.DAU.lastLaunchInfo.value = secsMonthYear
        
        return params
    }
    
    var channelParam: String {
        return "&channel=\(AppConstants.BuildChannel.isRelease ? "stable" : "beta")"
    }
    
    var versionParam: String {
        var version = AppInfo.appVersion
        
        if DAU.shouldAppend0ToAppVersion(version) {
            version += ".0"
        }
        
        return "&version=\(version)"
    }

    /// All app versions for dau pings must be saved in x.x.x format where x are digits.
    static func shouldAppend0ToAppVersion(_ version: String) -> Bool {
        let correctAppVersionPattern = "^\\d+.\\d+$"
        do {
            let regex = try NSRegularExpression(pattern: correctAppVersionPattern, options: [])
            let match = regex.firstMatch(in: version, options: [], range: NSRange(location: 0, length: version.count))
            
            return match != nil
        } catch {
            log.error("Version regex pattern error")
            return false
        }
    }
    
    func firstLaunchParam(_ isFirst: Bool) -> String {
        return "&first=\(isFirst)"
    }
    
    /** All first app installs are normalized to first day of the week.
     Eg. user installs app on wednesday 2017-22-11, his install date is recorded as of 2017-20-11(Monday) */
    var weekOfInstallationParam: String {
        let base = "&woi="
        
        // This _should_ be set all the time
        guard let woi = Preferences.DAU.weekOfInstallation.value else {
            log.error("woi, is nil, using default")
            return base + DAU.defaultWoiDate
        }
        return base + woi
    }
    
    /// Returns nil if no dau changes detected.
    func dauStatParams(_ dauStat: [Int?]?, firstPing: Bool) -> String? {
        func dauParams(_ daily: Bool, _ weekly: Bool, _ monthly: Bool) -> String {
            return "&daily=\(daily)&weekly=\(weekly)&monthly=\(monthly)"
        }
        
        if firstPing || AppConstants.BuildChannel == .developer {
            return dauParams(true, true, true)
        }
        
        let month = todayComponents.month
        let year = todayComponents.year
        
        guard let stat = dauStat?.compactMap({ $0 }) else {
            log.error("Cannot cast dauStat to [Int]")
            return nil
        }
        
        guard stat.count == 3 else {
            log.error("dauStat array must contain exactly 3 elements")
            return nil
        }
        
        let dSecs = Int(today.timeIntervalSince1970) - stat[0]
        let _month = stat[1]
        let _year = stat[2]
        let SECONDS_IN_A_DAY = 86400
        let SECONDS_IN_A_WEEK = 7 * 86400
        
        // On first ping, the user is all three of these
        let daily = dSecs >= SECONDS_IN_A_DAY
        let weekly = dSecs >= SECONDS_IN_A_WEEK
        let monthly = month != _month || year != _year
        log.debug("Dau stat params, daily: \(daily), weekly: \(weekly), monthly:\(monthly), dSecs: \(dSecs)")
        if (!daily && !weekly && !monthly) {
            // No changes, no ping
            return nil
        }
        
        return dauParams(daily, weekly, monthly)
    }
}

extension DateComponents {
    /// Returns date of current week's monday in YYYY-MM-DD format
    var weeksMonday: String {
        var isSunday: Bool {
            guard let weekday = weekday else {
                log.error("Weekday is nil")
                return false
            }
            return weekday == 1
        }
        
        // Make sure all required date components are set.
        guard let _ = day, let _ = month, let _ = year, let weekday = weekday else {
            log.error("Date components are missing")
            return ""
        }
        
        guard let today = Calendar.current.date(from: self) else {
            log.error("Cannot create date from date components")
            return ""
        }
        
        let dayInSeconds = 60 * 60 * 24
        // Sunday is first weekday so we need to handle this day differently, can't just substract it.
        let sundayToMondayDayDifference = 6
        let dayDifference = isSunday ? sundayToMondayDayDifference : weekday - 2 // -2 because monday is second weekday
        
        let monday = Date(timeInterval: -TimeInterval(dayDifference * dayInSeconds), since: today)
        let mondayComponents = (Calendar.current as NSCalendar).components([.day, .month , .year], from: monday)
        
        guard let mYear = mondayComponents.year, let mMonth = mondayComponents.month, let mDay = mondayComponents.day else {
            log.error("First monday of the week components are nil")
            return ""
        }
        
        return "\(mYear)-\(mMonth)-\(mDay)"
    }
}
