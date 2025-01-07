# ReqRes - Modern Web Debugging Proxy

<img width="2280" alt="image" src="https://reqresapp.com/_next/image/?url=%2F_next%2Fstatic%2Fmedia%2Fmain-window-dark%402x.aa1a7b8d.png&w=3840&q=75">

ReqRes is the ultimate developer tool for capturing, intercepting, and debugging HTTP(s) traffic on macOS. Designed for web developers, API testers, and network engineers, ReqRes makes tracking, analyzing, and modifying HTTP(s) requests and responses a breeze, all in real-time.

Key Features:
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


## FAQ

### I can't start the Network extension 

Most likely, it wasn't approved on the OS level after ReqRes was installed. It can be done in the Network Extensions preferences. Go to `System Settings > General > Login Items & Extensions > Network Extensions`.

<img width="891" alt="image" src="https://github.com/user-attachments/assets/1d119956-062f-42c3-b0a7-dc37ad542e75" />


The Network Extensions popup shows up after the Information icon is clicked (from the previous screenshot). ReqRes must be enabled:

<img width="594" alt="image" src="https://github.com/user-attachments/assets/7a58a2c6-3604-4932-96dd-7e4bb71c43a0" />

Try starting the network monitoring again after it's enabled.
