#!/opt/homebrew/bin/python3
"""A fake App Store Connect for release-test (LeanNativeTest/Release.lean): every endpoint the
`leannative-release testflight` steps use except `upload` (altool), as one app's records in memory.

Writes change the records, and a state App Store Connect reaches over minutes (a build processing, a
review submission) is reached at once. It never answers 5xx: curl retries a GET that gets one, the
test means to see App Store Connect's refusals. Stdlib only, safe under `python3 -I`.

    fake_asc.py           binds 127.0.0.1:0, prints the port, exits when stdin closes

Outside the API, under /_fake:

    POST /_fake/reset      the default records with the body's keys over them (see DEFAULT), and an
                           empty request log; "faults" is a list of {"method", "path", "status",
                           "times"}: the first `times` requests with that method whose path (without the
                           query) starts with `path` get `status` and Apple's error JSON
    GET  /_fake/requests   {"requests": [{"method", "path", "authorization", "body"}]}, oldest first
"""
import copy
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import sys
import threading
from urllib.parse import parse_qs, urlsplit

DEFAULT = {
    "bundleIds": [],
    "apps": [],
    "builds": [{"id": "BUILD1", "version": "42", "preReleaseVersion": "1.2.3", "uploadedDate": "2026-11-04T00:00:00Z",
                "processing": ["VALID"]}],  # the states GET /builds/<id> answers in turn; the last one stays
    "betaBuildLocalizations": [],  # {"id", "build", "locale", "whatsNew"}
    "internalBuildState": "READY_FOR_BETA_TESTING",
    "externalBuildState": "READY_FOR_BETA_SUBMISSION",
    "betaGroups": [{"id": "GROUP1", "name": "Public", "publicLinkId": "LINK1",
                    "publicLink": "https://testflight.apple.com/join/LINK1/", "isInternalGroup": False,
                    "publicLinkEnabled": True, "builds": []}],
    "betaReviews": {},  # build id → betaReviewState
    "appStoreVersions": [{"id": "VER1", "versionString": "1.2.3", "appVersionState": "PREPARE_FOR_SUBMISSION",
                          "platform": "IOS", "releaseType": "MANUAL", "build": None}],
    "appStoreVersionLocalizations": [{"id": "VLOC1", "version": "VER1", "locale": "en-US", "whatsNew": "",
                                      "description": "A probe.", "keywords": "probe",
                                      "supportUrl": "https://example.com/support", "marketingUrl": "",
                                      "promotionalText": "", "screenshotSets": ["SET1"]}],
    "screenshotSets": {"SET1": "APP_IPHONE_67"},
    "appInfos": [{"id": "INFO1", "state": "PREPARE_FOR_SUBMISSION", "appStoreAgeRating": "FOUR_PLUS",
                  "primaryCategory": "UTILITIES",
                  "localizations": [{"id": "ILOC1", "locale": "en-US", "name": "Probe", "subtitle": "",
                                     "privacyPolicyUrl": "https://example.com/privacy"}]}],
    "reviewSubmissions": [],  # {"id", "state", "items"}
    "echoNotes": True,  # False: a localization write answers with other text than was sent
    "faults": [],
}

state = copy.deepcopy(DEFAULT)
log = []
counter = [0]


def new_id(prefix):
    counter[0] += 1
    return f"{prefix}{counter[0]}"


def row(type_, id_, attributes, relationships=None):
    r = {"type": type_, "id": id_, "attributes": attributes}
    if relationships is not None:
        r["relationships"] = relationships
    return r


def ref(type_, id_):
    return {"data": None if id_ is None else {"type": type_, "id": id_}}


def app_ok(app_id):
    return any(a["id"] == app_id for a in state["apps"])


def build_row(b):
    return row("builds", b["id"], {"version": b["version"], "processingState": b["processing"][0],
                                   "uploadedDate": b["uploadedDate"]})


def pre_release(b):
    return row("preReleaseVersions", "PRE-" + b["id"], {"version": b["preReleaseVersion"], "platform": "IOS"})


def find(rows, id_):
    return next((r for r in rows if r["id"] == id_), None)


def localization_row(type_, loc):
    keys = ("locale", "whatsNew") if type_ == "betaBuildLocalizations" else (
        "locale", "whatsNew", "description", "keywords", "supportUrl", "marketingUrl", "promotionalText")
    rels = None
    if type_ == "appStoreVersionLocalizations":
        rels = {"appScreenshotSets": {"data": [{"type": "appScreenshotSets", "id": s} for s in loc["screenshotSets"]]}}
    return row(type_, loc["id"], {k: loc[k] for k in keys}, rels)


def version_row(v):
    return row("appStoreVersions", v["id"], {k: v[k] for k in ("versionString", "appVersionState", "platform",
                                                                "releaseType")},
               {"build": ref("builds", v["build"])})


def not_found(what):
    return 404, {"errors": [{"status": "404", "code": "NOT_FOUND", "title": "The specified resource does not exist",
                             "detail": what}]}


def set_text(type_, method, parts, body):
    data = body["data"]
    attrs = data.get("attributes", {})
    rows = state[type_]
    if method == "PATCH":
        loc = find(rows, parts[1])
        if loc is None:
            return not_found(f"There is no resource of type '{type_}' with id '{parts[1]}'")
    else:
        rel = next(iter(data["relationships"].values()))["data"]["id"]
        loc = {"id": new_id("LOC"), "locale": attrs["locale"], "whatsNew": ""}
        if type_ == "betaBuildLocalizations":
            loc["build"] = rel
        else:
            loc.update(version=rel, description="", keywords="", supportUrl="", marketingUrl="", promotionalText="",
                       screenshotSets=[])
        rows.append(loc)
    loc["whatsNew"] = attrs["whatsNew"]
    answer = localization_row(type_, loc)
    if not state["echoNotes"]:
        answer["attributes"]["whatsNew"] = "Something else."
    return (200 if method == "PATCH" else 201), {"data": answer}


def get(parts, q):
    one = lambda k: q.get(k, [""])[0]
    if parts == ["bundleIds"]:
        return 200, {"data": [row("bundleIds", b["id"], {"identifier": b["identifier"], "name": b["name"],
                                                         "platform": "IOS"})
                              for b in state["bundleIds"] if b["identifier"] == one("filter[identifier]")]}
    if parts == ["apps"]:
        return 200, {"data": [row("apps", a["id"], {"bundleId": a["bundleId"], "name": a["name"]})
                              for a in state["apps"] if a["bundleId"] == one("filter[bundleId]")]}
    if parts == ["builds"]:
        found = state["builds"] if app_ok(one("filter[app]")) else []
        if "filter[version]" in q:
            found = [b for b in found if b["version"] == one("filter[version]") and
                     b["preReleaseVersion"] == one("filter[preReleaseVersion.version]")]
        if "filter[betaGroups]" in q:
            group = find(state["betaGroups"], one("filter[betaGroups]"))
            found = [b for b in found if group and b["id"] in group["builds"]]
        if "filter[id]" in q:
            found = [b for b in found if b["id"] == one("filter[id]")]
        if one("sort") == "-uploadedDate":
            found = sorted(found, key=lambda b: b["uploadedDate"], reverse=True)
        found = found[:int(one("limit") or 50)]
        answer = {"data": [build_row(b) for b in found]}
        if one("include") == "preReleaseVersion":
            answer["included"] = [pre_release(b) for b in found]
        return 200, answer
    if parts[0] == "builds" and len(parts) >= 2:
        b = find(state["builds"], parts[1])
        if b is None:
            return not_found(f"There is no resource of type 'builds' with id '{parts[1]}'")
        if len(parts) == 2:
            answer = {"data": build_row(b)}
            if one("include") == "preReleaseVersion":
                answer["included"] = [pre_release(b)]
            elif len(b["processing"]) > 1:
                b["processing"].pop(0)
            return 200, answer
        if parts[2] == "betaBuildLocalizations":
            return 200, {"data": [localization_row("betaBuildLocalizations", l)
                                  for l in state["betaBuildLocalizations"] if l["build"] == b["id"]]}
        if parts[2] == "buildBetaDetail":
            return 200, {"data": row("buildBetaDetails", b["id"], {"internalBuildState": state["internalBuildState"],
                                                                    "externalBuildState": state["externalBuildState"]})}
    if parts == ["betaGroups"]:
        found = state["betaGroups"] if app_ok(one("filter[app]")) else []
        return 200, {"data": [row("betaGroups", g["id"], {k: g[k] for k in ("name", "publicLink", "publicLinkId",
                                                                              "isInternalGroup", "publicLinkEnabled")})
                              for g in found if g["publicLinkEnabled"]]}
    if parts == ["betaAppReviewSubmissions"]:
        bid = one("filter[build]")
        found = [row("betaAppReviewSubmissions", "BR-" + bid, {"betaReviewState": state["betaReviews"][bid]})] \
            if bid in state["betaReviews"] else []
        return 200, {"data": found}
    if parts[0] == "apps" and len(parts) == 3 and app_ok(parts[1]):
        if parts[2] == "appStoreVersions":
            return 200, {"data": [version_row(v) for v in state["appStoreVersions"]
                                  if v["versionString"] == one("filter[versionString]")]}
        if parts[2] == "appInfos":
            infos, included = [], []
            for i in state["appInfos"]:
                infos.append(row("appInfos", i["id"], {"state": i["state"], "appStoreAgeRating": i["appStoreAgeRating"]},
                                 {"primaryCategory": ref("appCategories", i["primaryCategory"]),
                                  "appInfoLocalizations": {"data": [{"type": "appInfoLocalizations", "id": l["id"]}
                                                                    for l in i["localizations"]]}}))
                included += [row("appInfoLocalizations", l["id"], {k: l[k] for k in ("locale", "name", "subtitle",
                                                                                      "privacyPolicyUrl")})
                             for l in i["localizations"]]
            return 200, {"data": infos, "included": included}
    if parts[0] == "appStoreVersions" and len(parts) >= 2:
        v = find(state["appStoreVersions"], parts[1])
        if v is None:
            return not_found(f"There is no resource of type 'appStoreVersions' with id '{parts[1]}'")
        locs = [l for l in state["appStoreVersionLocalizations"] if l["version"] == v["id"]]
        if len(parts) == 2:
            b = find(state["builds"], v["build"])
            return 200, {"data": version_row(v), "included": ([build_row(b)] if b else []) +
                         [localization_row("appStoreVersionLocalizations", l) for l in locs]}
        if parts[2] == "build":
            b = find(state["builds"], v["build"])
            return 200, {"data": build_row(b) if b else None}
        if parts[2] == "appStoreVersionLocalizations":
            answer = {"data": [localization_row("appStoreVersionLocalizations", l) for l in locs]}
            if one("include") == "appScreenshotSets":
                answer["included"] = [row("appScreenshotSets", s, {"screenshotDisplayType": state["screenshotSets"][s]})
                                      for l in locs for s in l["screenshotSets"]]
            return 200, answer
    if parts == ["reviewSubmissions"]:
        states = one("filter[state]").split(",")
        found = [s for s in state["reviewSubmissions"] if s["state"] in states] if app_ok(one("filter[app]")) else []
        return 200, {"data": [row("reviewSubmissions", s["id"], {"state": s["state"], "platform": "IOS"}) for s in found]}
    if parts[0] == "reviewSubmissions" and len(parts) == 2:
        s = find(state["reviewSubmissions"], parts[1])
        if s is None:
            return not_found(f"There is no resource of type 'reviewSubmissions' with id '{parts[1]}'")
        return 200, {"data": row("reviewSubmissions", s["id"], {"state": s["state"], "platform": "IOS"})}
    return not_found(f"The path /{'/'.join(parts)} is not one the fake knows")


def write(method, parts, body):
    data = (body or {}).get("data")
    if method == "POST" and parts == ["bundleIds"]:
        a = data["attributes"]
        b = {"id": new_id("BUNDLE"), "identifier": a["identifier"], "name": a["name"]}
        state["bundleIds"].append(b)
        return 201, {"data": row("bundleIds", b["id"], {"identifier": b["identifier"], "name": b["name"]})}
    if method == "POST" and parts == ["apps"]:
        a = data["attributes"]
        bundle = data["relationships"]["bundleId"]["data"]["id"]
        if not any(b["id"] == bundle and b["identifier"] == a["bundleId"] for b in state["bundleIds"]):
            return 409, {"errors": [{"status": "409", "code": "ENTITY_ERROR.RELATIONSHIP.INVALID",
                                     "title": "The provided entity includes a relationship with an invalid value",
                                     "detail": f"bundleId '{bundle}' does not match {a['bundleId']}"}]}
        app = {"id": new_id("APP"), "bundleId": a["bundleId"], "name": a["name"], "sku": a["sku"]}
        state["apps"].append(app)
        return 201, {"data": row("apps", app["id"], {"bundleId": app["bundleId"], "name": app["name"]})}
    if parts[0] in ("betaBuildLocalizations", "appStoreVersionLocalizations") and (
            (method == "POST" and len(parts) == 1) or (method == "PATCH" and len(parts) == 2)):
        return set_text(parts[0], method, parts, body)
    if method == "POST" and len(parts) == 4 and parts[0] == "betaGroups" and parts[2:] == ["relationships", "builds"]:
        group = find(state["betaGroups"], parts[1])
        if group is None:
            return not_found(f"There is no resource of type 'betaGroups' with id '{parts[1]}'")
        group["builds"] += [d["id"] for d in data if d["id"] not in group["builds"]]
        return 204, None
    if method == "POST" and parts == ["betaAppReviewSubmissions"]:
        bid = data["relationships"]["build"]["data"]["id"]
        state["betaReviews"][bid] = "WAITING_FOR_REVIEW"
        return 201, {"data": row("betaAppReviewSubmissions", "BR-" + bid, {"betaReviewState": "WAITING_FOR_REVIEW"})}
    if method == "PATCH" and len(parts) == 2 and parts[0] == "appStoreVersions":
        v = find(state["appStoreVersions"], parts[1])
        if v is None:
            return not_found(f"There is no resource of type 'appStoreVersions' with id '{parts[1]}'")
        v.update(data.get("attributes", {}))
        b = data.get("relationships", {}).get("build", {}).get("data")
        if b is not None:
            v["build"] = b["id"]
        return 200, {"data": version_row(v)}
    if method == "POST" and parts == ["reviewSubmissions"]:
        s = {"id": new_id("RS"), "state": "READY_FOR_REVIEW", "items": []}
        state["reviewSubmissions"].append(s)
        return 201, {"data": row("reviewSubmissions", s["id"], {"state": s["state"], "platform": "IOS"})}
    if method == "POST" and parts == ["reviewSubmissionItems"]:
        rels = data["relationships"]
        s = find(state["reviewSubmissions"], rels["reviewSubmission"]["data"]["id"])
        if s is None:
            return not_found("no such review submission")
        s["items"].append(rels["appStoreVersion"]["data"]["id"])
        return 201, {"data": row("reviewSubmissionItems", new_id("RSI"), {"state": "READY_FOR_REVIEW"})}
    if method == "PATCH" and len(parts) == 2 and parts[0] == "reviewSubmissions":
        s = find(state["reviewSubmissions"], parts[1])
        if s is None:
            return not_found(f"There is no resource of type 'reviewSubmissions' with id '{parts[1]}'")
        if data.get("attributes", {}).get("submitted") is True:
            if not s["items"]:
                return 409, {"errors": [{"status": "409", "code": "STATE_ERROR", "title": "The submission has no items",
                                         "detail": f"reviewSubmission '{s['id']}' has no items to submit"}]}
            s["state"] = "WAITING_FOR_REVIEW"
        return 200, {"data": row("reviewSubmissions", s["id"], {"state": s["state"], "platform": "IOS"})}
    return not_found(f"{method} /{'/'.join(parts)} is not one the fake knows")


def fault(method, path):
    for f in state["faults"]:
        if f["method"] == method and path.startswith(f["path"]) and f["times"] > 0:
            f["times"] -= 1
            code = str(f["status"])
            return f["status"], {"errors": [{"status": code, "code": "FAKE_" + code, "title": "A planted refusal",
                                             "detail": f"the fake refuses {method} {path} with {code}"}]}
    return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        raw = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        if raw:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_any(self, method):
        global state
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        body = json.loads(raw) if raw else None
        url = urlsplit(self.path)
        if url.path == "/_fake/reset" and method == "POST":
            state = copy.deepcopy(DEFAULT)
            state.update(copy.deepcopy(body or {}))
            if any(f["status"] >= 500 for f in state["faults"]):
                return self.answer(400, {"error": "the fake never answers 5xx"})
            log.clear()
            counter[0] = 0
            return self.answer(200, {"ok": True})
        if url.path == "/_fake/requests" and method == "GET":
            return self.answer(200, {"requests": log})
        log.append({"method": method, "path": self.path, "authorization": self.headers.get("Authorization"),
                    "body": body})
        if not url.path.startswith("/v1/"):
            return self.answer(*not_found(f"{url.path} is not under /v1"))
        planted = fault(method, url.path)
        if planted:
            return self.answer(*planted)
        parts = url.path[len("/v1/"):].split("/")
        q = parse_qs(url.query, keep_blank_values=True)
        try:
            self.answer(*(get(parts, q) if method == "GET" else write(method, parts, body)))
        except (KeyError, TypeError, AttributeError, IndexError, ValueError) as e:
            self.answer(409, {"errors": [{"status": "409", "code": "ENTITY_ERROR", "title": "The request is malformed",
                                          "detail": f"{method} {url.path}: {type(e).__name__} {e}"}]})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PATCH(self):
        self.handle_any("PATCH")

    def do_DELETE(self):
        self.handle_any("DELETE")


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)

    def watch_stdin():
        sys.stdin.read()
        os._exit(0)

    threading.Thread(target=watch_stdin, daemon=True).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
