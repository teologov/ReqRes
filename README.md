# 🚀 ReqRes – A Modern Web Debugging Proxy for macOS

**ReqRes** is a modern, high-performance, native web debugging proxy for macOS.
It lets you capture, inspect, modify, and intercept HTTP(S) traffic in real time.

<img width="2280" alt="image" src="https://reqresapp.com/_next/image/?url=%2F_next%2Fstatic%2Fmedia%2Fmain-window-no-bg-dark%402x.7ec2b792.png&w=1920&q=75">

### 🔑 Key Features

* 🔍 **Real-time HTTP(S) Traffic Monitoring**  
  Instantly capture and view HTTP(S) requests and responses from your macOS apps, browsers, and APIs.
* ✋ **Request & Response Interception**  
  Intercept and modify traffic on the fly—change headers, status codes, or entire response bodies. Map requests to local files for faster testing and development.
* 🧪 **Detailed Inspection**  
  Dive deep into every request and response with an intuitive interface—view headers, methods, status codes, and payloads with ease.
* 📂 **Session Management**  
  Organize, filter, and search through captured sessions so you can focus on what matters most.
* 🗂️ **Local File Mapping**  
  Speed up API testing by mapping network requests to local files. Simulate offline scenarios and serve mock data instantly.
* 🖼️ **Image Preview**  
  Instantly view image responses inside the app—ideal for debugging media-heavy APIs.
* 🎯 **Customizable Filters**  
  Filter traffic by host, method, or status code to quickly narrow down your results.
* 🔎 **Integrated Search Bar**  
  Quickly find specific requests or responses with powerful built-in search.
* 📤 **Session Export**  
  Export captured traffic in multiple formats for analysis or collaboration with your team.

ReqRes is the perfect companion for developers who need full control over their network traffic. From intercepting and modifying requests and responses to organizing and analyzing sessions, ReqRes ensures your development and debugging processes are faster and more efficient.

## License

This project is licensed under FSL-1.1-ALv2 - see the [LICENSE.md](LICENSE.md) file for details.

For third-party dependencies and their licenses, see [LICENSE-THIRD-PARTY.md](LICENSE-THIRD-PARTY.md).

# Development Setup & Configuration

## Overview

This project requires a local configuration file to run. The app expects two environment variables: `DEVELOPMENT_TEAM` (required for code signing) and `SENTRY_DSN` (optional for crash reporting). The app will still work without Sentry configuration.

## Quick Setup

1. **Copy the configuration template:**
   ```bash
   cp Config.xcconfig.template Config.xcconfig
   ```

2. **Edit `Config.xcconfig` with your values:**
   ```bash
   # Open in your preferred editor
   nano Config.xcconfig
   ```

3. **Add your development credentials:**
   - `DEVELOPMENT_TEAM`: Your Apple Developer Team ID (required)
   - `SENTRY_DSN`: Your Sentry project DSN (optional)

4. **Build and run the project**

## Troubleshooting

### Configuration not loading?
1. Verify `Config.xcconfig` exists and has correct syntax (no quotes around values)
2. Check that the config file is linked in Project Settings → Info → Configurations
3. Clean build folder (Product → Clean Build Folder) and rebuild
4. Ensure variable names match exactly between config file and Info.plist

### Build errors about missing Team ID?
1. Make sure `DEVELOPMENT_TEAM` is set in your `Config.xcconfig`
2. Verify you have valid Apple Developer account access
3. You can leave `DEVELOPMENT_TEAM` empty to use local signing

## FAQ

### Is app sandboxed?
Yes.

### Do you have a roadmap?
As of Q2 2025, we're gathering feedback and working on proper user documentation.
We will provide a more detailed roadmap later this year.

### Do you accept PRs?
Yes. Pull Requests are accepted for UI bug fixes. We are not ready yet to accept Pull Requests for the server side.

### I can't start the Network extension 

It was most likely not approved on the OS level after ReqRes was installed. It can be done using the Network Extensions preferences. Go to `System Settings > General > Login Items & Extensions > Network Extensions`.

<img width="891" alt="image" src="https://github.com/user-attachments/assets/1d119956-062f-42c3-b0a7-dc37ad542e75" />


The Network Extensions popup shows up after the Information icon is clicked (from the previous screenshot). ReqRes must be enabled:

<img width="594" alt="image" src="https://github.com/user-attachments/assets/7a58a2c6-3604-4932-96dd-7e4bb71c43a0" />

Try starting the network monitoring again after it's enabled.
