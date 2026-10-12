# Reporting a security issue

If you find a vulnerability in ISR, please report it privately rather than in
a public issue.

**How:** open the repository's **Security** tab and choose **Report a
vulnerability**. That opens a private advisory that only you and the ISR
maintainers can see. Include the ISR version (shown at the top of the console
and by `/api/isr/version`), how ISR is deployed, and the steps to reproduce.

**What to expect:** an acknowledgement within five working days, a fix or a
mitigation in a release, and credit in the release notes if you want it.

**What is in scope:** the ISR binary and console, the installers, and the
documentation in this repository. The InfluxDB 3 engine itself, the cloud
services ISR fronts, and third-party tools ISR integrates with have their own
reporting channels.

**Supported versions:** the latest 4.x release. Earlier releases are not
updated; upgrade first, then report if the issue is still present.

Please do not run tests against ISR deployments you do not own.
