# hackrice26-precode — Apple Watch → HealthKit → iPhone → Backend

A hackathon prototype pipeline that reads Apple Watch data from HealthKit on an
iPhone, normalizes it into JSON, and POSTs it to a local backend.

```
Apple Watch → Apple Health / HealthKit → iOS app → HealthSnapshot JSON → POST /vitals → backend processing
```

**This is not a medical device and its output is not medical advice.**

## Layout

```
ios/
├── HealthHackathon.xcodeproj      # open this in Xcode
├── Config/
│   ├── Info.plist                 # HealthKit + local-network usage strings, ATS
│   └── HealthHackathon.entitlements
└── HealthHackathon/
    ├── HealthHackathonApp.swift
    ├── ContentView.swift
    ├── AppConfig.swift            # backend URL + random tester ID
    ├── Models/HealthSnapshot.swift
    ├── Services/HealthKitManager.swift
    ├── Services/APIClient.swift
    └── Views/HealthDashboardView.swift

backend/                             # Express + TypeScript
├── package.json
├── tsconfig.json
├── public/index.html                # live local dashboard
└── src/
    ├── index.ts                     # mounts /vitals, /dashboard, /health
    ├── types.ts                     # mirrors the Swift models 1:1
    ├── routes/vitals.ts             # POST /vitals and friends
    ├── services/validateSnapshot.ts # payload validation
    ├── services/vitalsAnalysis.ts   # ← plug the game logic in here
    ├── services/vitalsStore.ts      # in-memory ring buffer
    └── scripts/sendDemoSnapshot.ts  # synthetic data, no phone needed
```

## 1. Run the backend

```bash
cd backend
npm install
npm run dev
```

It binds `0.0.0.0` — the iPhone connects over Wi-Fi, so loopback-only won't do.
Find the address to enter on the phone with:

```bash
ipconfig getifaddr en0     # e.g. 192.168.1.42 -> http://192.168.1.42:4000
```

Check it:

```bash
curl http://localhost:4000/health
curl -X POST http://localhost:4000/vitals \
  -H 'Content-Type: application/json' \
  -d '{"timestamp":"2026-09-05T21:00:00Z","testerId":"tester_01",
       "heartRateBpm":74,"restingHeartRateBpm":62,"hrvMs":48,
       "stepsToday":6827,"activeCaloriesToday":493}'
```

Endpoints: `POST /vitals`, `GET /vitals/latest`, `GET /vitals/recent`,
`POST /vitals/reset`, `GET /health`, and the dashboard at `/dashboard/`.

The data route is `/vitals` rather than `/health` because `GET /health` is
already the service's liveness check.

## 2. Watch it locally

Open **http://localhost:4000/dashboard/**. It polls the backend every 3s and shows
the five metrics, the backend's analysis, and a table of recent snapshots.
Missing metrics render as "Unavailable", never `0`.

To see it working before any phone is involved, push synthetic data through it:

```bash
cd backend && npx ts-node-dev src/scripts/sendDemoSnapshot.ts --count 10 --interval 2
```

Those values are randomly generated and belong to no one — use them for demos and
screenshots instead of real health data.

## 3. Run the iOS app on a physical iPhone

HealthKit returns no real data in the Simulator — use an actual iPhone that is
paired with an Apple Watch.

1. `open ios/HealthHackathon.xcodeproj`
2. Target **HealthHackathon** → *Signing & Capabilities*: pick your **Team**, and
   change **Bundle Identifier** to something unique (e.g. `com.yourname.HealthHackathon`).
   The **HealthKit** capability is already in the entitlements file and should
   appear here automatically.
3. Point the app at your Mac. `localhost` on an iPhone means *the iPhone itself*,
   so use your Mac's LAN address:
   ```bash
   ipconfig getifaddr en0     # e.g. 192.168.1.42
   ```
   Set it either in the app's **Backend** text field at runtime, or once in
   *Build Settings → BACKEND_BASE_URL* (e.g. `http://192.168.1.42:4000`).
   Both devices must be on the same Wi-Fi.
4. Build and run on the device, tap **Connect Apple Health**, grant the requested
   types, then **Refresh Health Data** and **Send to Backend**.

On the first send iOS also asks for Local Network permission — allow it.

**If the phone can't reach the Mac:** many campus and conference networks isolate
clients from each other, which blocks phone → laptop connections no matter how
the app is configured. Test with Safari on the iPhone at
`http://<your-mac-ip>:4000/health`. If that hangs, turn on **Personal Hotspot**
on the iPhone, join the Mac to it, re-run `./backend/run.sh` to get the new
address, and use that instead.

## Payload contract

```json
{
  "timestamp": "2026-09-05T21:00:00Z",
  "testerId": "tester_a1b2c3d4",
  "heartRateBpm": 74,
  "restingHeartRateBpm": null,
  "hrvMs": 48,
  "stepsToday": 6827,
  "activeCaloriesToday": 493,
  "exerciseMinutesToday": 24,
  "exerciseGoalMinutes": 30,
  "standHoursToday": 9,
  "standGoalHours": 12,
  "recentWorkouts": [
    {
      "activityType": "Running",
      "start": "2026-09-05T18:00:00Z",
      "end": "2026-09-05T18:32:00Z",
      "durationMinutes": 32,
      "activeCalories": 310,
      "distanceMeters": 5120,
      "averageHeartRateBpm": 152,
      "maxHeartRateBpm": 171
    }
  ]
}
```

Keys are camelCase, matching `backend/src/types.ts`, which mirrors the Swift
models 1:1.

### Activity rings and workouts

Exercise minutes and stand hours come from `HKActivitySummaryQuery` — the same
source the Fitness app draws its rings from — so they carry the user's goals too.
Note that `stand_hours_today` is the ring's **hour count** (goal normally 12), not
`appleStandTime`, which is minutes spent standing. Those are different HealthKit
values with confusingly similar names, and only the former matches the watch.

`recent_workouts` holds up to 5 completed workouts from the last 7 days, with
totals read via `HKWorkout.statistics(for:)` (the `totalEnergyBurned` and
`totalDistance` properties are deprecated as of iOS 18). Fields are null when the
activity did not record them — an indoor workout has no distance, and a workout
logged without the Watch has no heart rate.

**Completed workouts only.** A workout being tracked right now on the Watch is
not visible to this app; HealthKit publishes the sample after the session ends
and syncs. Live mid-workout data would require our own watchOS app running an
`HKWorkoutSession`, with the user starting the workout in *our* app rather than
Apple's — see "Optional Phase 2" in the pipeline spec.

A metric HealthKit has no sample for is sent as explicit `null`, never `0` —
`0 BPM` and "no data" are different statements. The backend accepts partial
snapshots and analyzes whatever arrived. The UI shows missing metrics as
"Unavailable".

`testerId` is a random per-install string. No names, Apple IDs, emails or phone
numbers are collected or sent.

## Privacy notes

- The app requests read access to: heart rate, resting heart rate, HRV (SDNN),
  step count, active energy, walking/running and cycling distance (used only to
  report workout distance), the activity summary (rings), and workouts. Nothing
  is written to HealthKit.
- The backend keeps snapshots **in memory only** (a ring buffer, default 100).
  Nothing is written to disk, so there is no health dataset to leak into Git.
- Server logs record which metrics arrived and the tester ID — never the values.
- Health exports, `node_modules/`, `dist/` and `xcuserdata/` are gitignored.
- There is no auth on the backend; it is meant to listen only on the hackathon
  Wi-Fi. Add a token before it goes anywhere public.

## Where the project's real logic goes

`backend/src/services/vitalsAnalysis.ts::analyze()` currently returns simple
derived strings so the round trip shows something on the phone. That is the seam
for the game logic — awarding crate keys for a closed exercise ring, feeding
battle stats. Its return value flows straight back to the app as `analysis`.

## Status

Verified: the backend runs and accepts full, partial, all-null and malformed
payloads (422 with a readable message); `HealthSnapshot` compiles and its encoded
JSON was POSTed to the running backend successfully; the dashboard renders live
data from the API.

Not yet verified: the iOS app has not been compiled, because Xcode was not
installed on the machine this was written on — only Command Line Tools. Every
Swift file parses and the Foundation-only files typecheck, but the HealthKit and
SwiftUI code needs a first build in Xcode. Deployment target is iOS 17.0.

Signing note: a free Apple ID signs the app for 7 days at a time (rebuild from
Xcode to reset it); a paid Developer Program membership lasts a year. Confirm at
the first build that the HealthKit capability is accepted by your team type.
