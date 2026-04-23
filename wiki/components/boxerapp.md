---
title: boxerApp.swift
updated: 2026-04-23
source: boxer/boxerApp.swift
---

# boxerApp

SwiftUI app entry point. Minimal — just a `@main` struct that vends a
`WindowGroup` hosting [`ContentView`](contentview.md). All state lives in
`ContentView` (via its `@StateObject var viewModel = ARViewModel()`), so
this file is essentially stock SwiftUI boilerplate.

If you need app-lifecycle hooks (backgrounding behaviour, URL handling,
multi-scene support), this is where they go. Nothing of that nature lives
here today.
