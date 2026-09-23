// Version.swift — the single source of truth for Pomoppi's version number.
// Scripts/make-app.js and Scripts/make-windows-app.js both regex-read
// pomoppiVersion out of this file (same trick refresh-art.js already uses
// to rewrite Settings.swift's friendIDs/backgroundIDs) rather than each
// hardcoding their own copy. Bump this, nothing else, to release a new
// version.
public let pomoppiVersion = "0.3.0"
