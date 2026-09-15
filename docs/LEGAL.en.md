# Legal & Usage Notice

> **This is not legal advice and is not a warranty of legality in any
> jurisdiction.** For distribution, store listing, export control, telecom or
> cybersecurity compliance, consult a licensed attorney. Platform policies and
> statutes change; current rules control.
>
> 中文：[`LEGAL.md`](LEGAL.md)

---

## 1. What this project is

XVPN (幽门 — the name shown in the app) is an **open-source client**, not a VPN
service, not a proxy operator, and not a marketplace for endpoints.

| This project does | This project does not |
| --- | --- |
| Parse **user-supplied** configuration files | **Provide** nodes, servers, subscriptions, or accounts |
| Build split-tunnel / DNS decisions and observe results | **Operate** any network access service for users |
| Drive the upstream open-source core (sing-box) | **Implement** cryptography (that is the core) |
| Store profiles and learned rules locally | **Collect or phone home** personal data ([`PRIVACY.md`](../PRIVACY.md)) |
| Publish source and build artifacts on GitHub | Help obtain third-party access or maintain node lists |

**In one sentence: you bring a lawful profile and server; this software is only
the client.**

Canonical repository: <https://github.com/LSD-Apps/XVPN>  
Mirror: <https://gitcode.com/start-ai/XVPN>  
Copyright: [`AUTHORS`](../AUTHORS), [`NOTICE.md`](../NOTICE.md),
[`CITATION.cff`](../CITATION.cff).

---

## 2. Intended lawful uses

The software is a generic network client. Typical, usually uncontroversial uses
include:

- Connecting to a server **you administer** (home NAS/router, cloud VM, lab host);
- Using a VPN/tunnel profile **formally issued** by an employer, school, or
  organisation to reach *their* network;
- Development, testing, and research of split routing, DNS consistency, and
  failure attribution on devices you are authorised to manage.

Legality depends **entirely** on the law where you and the server are, and on
your authorisation to use that server. This project does not review, warrant, or
endorse any third-party node, subscription source, or particular use.

---

## 3. What this repository will not accept

To keep the “client tool” positioning and to stay aligned with the
[GitHub Acceptable Use Policies](https://docs.github.com/site-policy/acceptable-use-policies/github-acceptable-use-policies),
the following will **not** land in this repository; related issues and PRs will
be closed:

1. **Nodes, subscriptions, accounts, invite codes**, or requests/answers about
   where to buy or obtain access;
2. Turning the project into an **operated access service** (hosted nodes, shared
   subscriptions, traffic resale);
3. **How-to guides for circumventing network controls or content filters** (the
   user guide only covers: bring your own server → import → connect → read the
   split);
4. Discussion or code for stolen credentials, unauthorised access to others’
   systems, or using the software as attack infrastructure;
5. Unredacted private keys, certificates, real server addresses, or passwords
   (see [`CONTRIBUTING.md`](../CONTRIBUTING.md)).

Technical notes ([`RULES.md`](RULES.md), [`RESILIENCE.md`](RESILIENCE.md)) record
**engineering measurements** of routing correctness, DNS consistency, and
failure attribution. They are **not** circumvention tutorials and not a promise
about any third party’s reachability or legality.

---

## 4. Your responsibilities

1. **Lawful use.** You must confirm that your profile, server, and purpose
   comply with the laws, export rules, and terms of service of your jurisdiction
   and of the server’s location — including any local licensing of telecom,
   cross-border networking, or commercial VPN.
2. **Bring your own service.** This project does not vet third-party sources.
   Importing a profile of unknown origin is at your risk.
3. **Credentials.** You keep private keys, certificates, and passwords; theft of
   the device or an unencrypted disk is your risk (see the privacy policy).
4. **Redistribution.** If you redistribute this project or its binaries, you
   must follow GPL-3.0-or-later and the duties in
   [`NOTICE.md`](../NOTICE.md) / [`THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md),
   and you **must not** use the sing-box name or imply affiliation.
5. **Using this repository.** Cloning, building, or contributing also requires
   compliance with GitHub’s (and any mirror’s) terms and acceptable use
   policies.
6. **First-launch acknowledgement.** A new install must acknowledge this notice
   on-device before the UI is usable. The flag is stored locally; Settings can
   reopen the full text. Installs that already had a save file from before this
   field existed are treated as acknowledged, so upgrades are not blocked.
   This is **not** legal advice and not a warranty of legality.

---

## 5. Open source and GitHub

Publishing this repository on GitHub is intended as **dual-use client source**
(the same class as public WireGuard / OpenVPN / sing-box clients): so people can
audit, learn, build, and redistribute under the GPL.

This repository:

- does **not** ship malware, stolen credentials, or attack infrastructure;
- does **not** provide ready-to-use network access (no nodes, no subscription
  backend);
- uses cryptography from an already-public upstream core; export-control notes
  are in [`RELEASE.md`](RELEASE.md).
- `testdata/` uses RFC reserved names and documentation IPs only — they do not
  connect, and they are not a node list.

**Open source is not automatically lawful in every country.** Maintainers cannot
and do not warrant that “putting the source on GitHub” satisfies every regulator
where you live. If your jurisdiction restricts using or distributing software of
this kind, do not use this project.

---

## 6. No warranty

To the extent permitted by applicable law, the software is provided “AS IS”
under the GPL, **without any express or implied warranty**, including
merchantability, fitness for a particular purpose, and non-infringement. Any
loss from using this software, or from a profile, server, or routing decision,
is borne by the user. See [`LICENSE`](../LICENSE).

---

## 7. Documentation tone

User-facing steps live in [`USER_GUIDE.md`](USER_GUIDE.md) /
[`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md): **your own server + this client**.
Server install is left to each protocol’s **official** docs. This project does
not point at third-party nodes or subscription vendors.

UI and README stay on “client + bring-your-own config”. Marketing must not imply
that this project provides nodes, subscriptions, or operated access.

---

## 8. Privacy, security, platform compliance

| Topic | Doc |
| --- | --- |
| Privacy (nothing collected; outbound list) | [`PRIVACY.md`](../PRIVACY.md) / [privacy.html](../privacy.html) |
| Vulnerability reports | [`SECURITY.md`](../SECURITY.md) |
| Release engineering, store policy, export notes | [`RELEASE.md`](RELEASE.md) |
| Google Play materials | [`STORE_LISTING.md`](STORE_LISTING.md) |
| Third-party licences | [`NOTICE.md`](../NOTICE.md) |
| Contribution boundaries | [`CONTRIBUTING.md`](../CONTRIBUTING.md) |

---

## 9. Upstream

XVPN is independent. It is **not affiliated with, endorsed by, or sponsored by**
sing-box / SagerNet. Name-use limits: [`NOTICE.md`](../NOTICE.md).
