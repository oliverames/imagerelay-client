const CALLBACK_PATHS = new Set(["/callback", "/oauth/callback"]);
const NATIVE_CALLBACK = "imagerelay-client://oauth/callback";
const PASSTHROUGH_QUERY_KEYS = ["code", "state", "error", "error_description"];

type WorkerHandler = {
  fetch(request: Request): Promise<Response>;
};

export default {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("Method Not Allowed", {
        status: 405,
        headers: {
          Allow: "GET, HEAD",
          "Cache-Control": "no-store",
        },
      });
    }

    if (!CALLBACK_PATHS.has(url.pathname)) {
      return new Response("Not Found", {
        status: 404,
        headers: {
          "Cache-Control": "no-store",
        },
      });
    }

    const nativeURL = buildNativeCallbackURL(url);
    if (request.method === "HEAD") {
      return new Response(null, {
        status: 204,
        headers: noStoreHeaders(),
      });
    }

    return new Response(callbackPage(nativeURL), {
      status: 200,
      headers: {
        ...noStoreHeaders(),
        "Content-Type": "text/html; charset=utf-8",
      },
    });
  },
} satisfies WorkerHandler;

function buildNativeCallbackURL(source: URL): string {
  const nativeURL = new URL(NATIVE_CALLBACK);
  for (const key of PASSTHROUGH_QUERY_KEYS) {
    for (const value of source.searchParams.getAll(key)) {
      nativeURL.searchParams.append(key, value);
    }
  }
  return nativeURL.toString();
}

function noStoreHeaders(): Record<string, string> {
  return {
    "Cache-Control": "no-store",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "Content-Security-Policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; navigate-to imagerelay-client:",
  };
}

function callbackPage(nativeURL: string): string {
  const escapedURL = escapeHTML(nativeURL);
  const scriptURL = JSON.stringify(nativeURL);

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="referrer" content="no-referrer">
  <title>Opening Image Relay</title>
  <style>
    body {
      color: #1f2937;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      margin: 0;
      padding: 32px;
    }

    a {
      color: #0f62fe;
    }
  </style>
</head>
<body>
  <p>Opening Image Relay...</p>
  <p><a href="${escapedURL}">Open Image Relay</a></p>
  <script>
    window.location.replace(${scriptURL});
  </script>
</body>
</html>`;
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
