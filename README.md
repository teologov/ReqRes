# ReqRes - Modern Web Debugging Proxy

ReqRes is the ultimate developer tool for capturing, intercepting, and debugging HTTP(s) traffic on macOS. Designed for web developers, API testers, and network engineers, ReqRes makes tracking, analyzing, and modifying HTTP(s) requests and responses a breeze, all in real time.


<img width="2280" alt="image" src="https://reqresapp.com/_next/image/?url=%2F_next%2Fstatic%2Fmedia%2Fmain-window-no-bg-dark%402x.7ec2b792.png&w=1920&q=75">

### Key Features

* Real-time HTTP(s) Traffic Monitoring: Instantly capture and view HTTP(s) requests and responses from your macOS apps, browsers, and APIs.
* Request and Response Interception: Seamlessly intercept HTTP(s) traffic to modify headers, status codes, and even entire response bodies. Customize responses by mapping requests to local files for faster development and testing.
* Detailed Inspection: Inspect every aspect of captured traffic, including headers, methods, status codes, and payloads, all in a user-friendly, organized interface.
* Session Management: Easily organize, filter, and search through captured sessions, allowing you to focus on the data that matters most.
* Local File Mapping: Speed up your API testing process by mapping network requests to local files, enabling custom responses or testing how your app handles offline data.
* Image Preview: View image responses directly within the app, perfect for debugging media APIs.
* Customizable Filters: Filter traffic based on hosts, methods, or status codes, allowing you to quickly pinpoint the information you need.
* Integrated Search Bar: Find specific requests or responses with ease using the built-in search functionality.
* Session Export: Export captured traffic in various formats for deeper analysis or sharing with your team.

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

## Configuration Files

### `Config.xcconfig` (Not tracked in Git)
This file contains your personal development configuration. **Never commit this file to git.**

Required values:
- `DEVELOPMENT_TEAM`: Your Apple Developer Team ID
- `SENTRY_DSN`: Your Sentry project DSN for crash reporting (optional)

### `Config.xcconfig.template` (Tracked in Git)
Template file showing the required configuration keys. Copy this to create your local `Config.xcconfig`.

## How It Works

The `Config.xcconfig` file is linked to both Debug and Release build configurations. Variables from the config file are automatically substituted into the project at build time.

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

### I can't start the Network extension 

It was most likely not approved on the OS level after ReqRes was installed. It can be done using the Network Extensions preferences. Go to `System Settings > General > Login Items & Extensions > Network Extensions`.

<img width="891" alt="image" src="https://github.com/user-attachments/assets/1d119956-062f-42c3-b0a7-dc37ad542e75" />


The Network Extensions popup shows up after the Information icon is clicked (from the previous screenshot). ReqRes must be enabled:

<img width="594" alt="image" src="https://github.com/user-attachments/assets/7a58a2c6-3604-4932-96dd-7e4bb71c43a0" />

Try starting the network monitoring again after it's enabled.
