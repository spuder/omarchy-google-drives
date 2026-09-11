// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("parseAccounts handles empty input without throwing", () => {
  const result = Model.parseAccounts("")
  assert.equal(result.ok, true)
  assert.deepEqual(result.accounts, [])
})

test("parseAccounts rejects malformed JSON with lastError set", () => {
  const result = Model.parseAccounts("{not json")
  assert.equal(result.ok, false)
  assert.match(result.lastError, /Failed to parse/)
})

test("parseAccounts normalizes a two-account payload", () => {
  const raw = JSON.stringify({
    ok: true,
    rcloneInstalled: true,
    accounts: [
      { id: "personal", displayName: "Personal", authenticated: true, timerEnabled: true, running: false, usedBytes: 100, quotaBytes: 1000, quotaKnown: true },
      { id: "work", authenticated: false }
    ]
  })
  const result = Model.parseAccounts(raw)
  assert.equal(result.accounts.length, 2)
  assert.equal(result.accounts[0].displayName, "Personal")
  // Missing displayName falls back to id, same as the Dropbox plugin falling
  // back to "Untitled" for a file with no name.
  assert.equal(result.accounts[1].displayName, "work")
  assert.equal(result.accounts[1].authenticated, false)
})

test("aggregateState prioritizes error over syncing over paused", () => {
  const syncing = [{ authenticated: true, timerEnabled: true, running: true, lastError: "" }]
  const errored = [{ authenticated: true, timerEnabled: true, running: true, lastError: "expired" }]
  const paused = [{ authenticated: true, timerEnabled: false, running: false, lastError: "" }]
  assert.equal(Model.aggregateState(syncing), "syncing")
  assert.equal(Model.aggregateState(errored), "error")
  assert.equal(Model.aggregateState(paused), "paused")
  assert.equal(Model.aggregateState([]), "empty")
})

test("aggregateSummary counts scheduled accounts", () => {
  const accounts = [
    { authenticated: true, timerEnabled: true, lastError: "" },
    { authenticated: true, timerEnabled: false, lastError: "" },
    { authenticated: true, timerEnabled: true, lastError: "" }
  ]
  assert.equal(Model.aggregateSummary(accounts), "2 of 3 syncing")
})

test("totalUsedBytes sums across accounts", () => {
  const accounts = [{ usedBytes: 100 }, { usedBytes: 250 }, {}]
  assert.equal(Model.totalUsedBytes(accounts), 350)
})

test("formatBytes uses SI-style units with sane precision", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(999), "999 B")
  assert.equal(Model.formatBytes(1500), "1.5 KB")
  assert.equal(Model.formatBytes(4_200_000_000), "4.2 GB")
})

test("usageText falls back to just usedBytes when quota is unknown", () => {
  assert.equal(Model.usageText(1500, 0, false), "1.5 KB")
  assert.equal(Model.usageText(1500, 20_000_000_000, true), "1.5 KB of 20 GB")
})

test("statusText reflects sign-in, sync, and pause state in priority order", () => {
  const now = 1_000_000
  assert.equal(Model.statusText({ authenticated: false }, now), "Not signed in")
  assert.equal(Model.statusText({ authenticated: true, running: true }, now), "Syncing…")
  assert.equal(Model.statusText({ authenticated: true, timerEnabled: true, needsResync: true }, now), "Waiting for first sync")
  assert.equal(Model.statusText({ authenticated: true, timerEnabled: false, needsResync: true }, now), "Paused (never synced)")
  assert.equal(Model.statusText({ authenticated: true, timerEnabled: false, needsResync: false, lastSyncAt: now - 100 }, now), "Paused")
  assert.equal(Model.statusText({ authenticated: true, timerEnabled: true, needsResync: false, lastSyncAt: now - 80 }, now), "Synced 1 minute ago")
})

test("relativeTime buckets sensibly", () => {
  const now = 1_000_000
  assert.equal(Model.relativeTime(now - 10, now), "just now")
  assert.equal(Model.relativeTime(now - 200, now), "3 minutes ago")
  assert.equal(Model.relativeTime(now - 7200, now), "2 hours ago")
  assert.equal(Model.relativeTime(now - 172800, now), "2 days ago")
})
