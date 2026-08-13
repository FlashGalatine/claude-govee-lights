using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace GoveeLights
{
    public class HttpRequest
    {
        public string Method = "";
        public string Path = "";
        public Dictionary<string, string> Query = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, string> Headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        public string Body = "";
    }

    public class HttpResponse
    {
        public int Status = 204;
        public string ContentType = "application/json";
        public string Body = "";

        public static HttpResponse NoContent() => new HttpResponse { Status = 204, Body = "" };
        public static HttpResponse Json(string json) => new HttpResponse { Status = 200, Body = json };
        public static HttpResponse Text(int status, string text) =>
            new HttpResponse { Status = status, ContentType = "text/plain; charset=utf-8", Body = text };
    }

    /// <summary>
    /// A deliberately small HTTP/1.1 subset over TcpListener.
    ///
    /// HttpListener would be the obvious choice, but it sits on http.sys and needs a
    /// `netsh http add urlacl` reservation to bind from a non-elevated process. The
    /// daemon is launched by Claude Code and must run unelevated with zero setup, so an
    /// elevated one-time provisioning step is unacceptable. We need exactly: request
    /// line, headers, Content-Length body, one response, close. That is ~150 lines.
    ///
    /// Binding to IPAddress.Loopback is also a hard security boundary - the socket is
    /// unreachable from off-box regardless of firewall state.
    /// </summary>
    public sealed class MiniHttpServer : IDisposable
    {
        readonly int _port;
        readonly Func<HttpRequest, HttpResponse> _handler;
        TcpListener _listener;
        Thread _accept;
        volatile bool _running;

        public MiniHttpServer(int port, Func<HttpRequest, HttpResponse> handler)
        {
            _port = port;
            _handler = handler;
        }

        /// <summary>Binding also serves as the single-instance lock: a second daemon
        /// fails here rather than silently double-driving the lights.</summary>
        public bool Start(out string error)
        {
            error = null;
            try
            {
                _listener = new TcpListener(IPAddress.Loopback, _port);
                _listener.ExclusiveAddressUse = true;
                _listener.Start(64);
            }
            catch (SocketException ex)
            {
                error = ex.SocketErrorCode == SocketError.AddressAlreadyInUse
                    ? string.Format("port {0} is already in use", _port)
                    : ex.Message;
                return false;
            }

            _running = true;
            _accept = new Thread(AcceptLoop) { Name = "http-accept", IsBackground = true };
            _accept.Start();
            Log.Info("http_listening", "bound", new Dictionary<string, object> { { "port", _port } });
            return true;
        }

        void AcceptLoop()
        {
            while (_running)
            {
                TcpClient client = null;
                try { client = _listener.AcceptTcpClient(); }
                catch (SocketException) { if (!_running) break; continue; }
                catch (ObjectDisposedException) { break; }

                // Hand off immediately. The accept loop must never block on Govee work -
                // this is what keeps a 2s hook timeout from ever mattering.
                var c = client;
                ThreadPool.QueueUserWorkItem(_ => Serve(c));
            }
        }

        void Serve(TcpClient client)
        {
            try
            {
                using (client)
                {
                    client.NoDelay = true;
                    client.ReceiveTimeout = 5000;
                    client.SendTimeout = 5000;

                    using (var stream = client.GetStream())
                    {
                        var req = ReadRequest(stream);
                        if (req == null) return;

                        HttpResponse resp;
                        try { resp = _handler(req) ?? HttpResponse.NoContent(); }
                        catch (Exception ex)
                        {
                            Log.Exception("http_handler_failed", ex);
                            resp = HttpResponse.Text(500, "handler error");
                        }

                        WriteResponse(stream, resp);
                    }
                }
            }
            catch (Exception ex) { Log.Debug("http_conn_failed", ex.Message); }
        }

        static HttpRequest ReadRequest(NetworkStream stream)
        {
            var head = new MemoryStream();
            var buf = new byte[1];
            int matched = 0;
            // Read byte-at-a-time until CRLFCRLF. Headers are tiny; this avoids having to
            // manage a buffer that straddles the header/body boundary.
            while (matched < 4)
            {
                int n = stream.Read(buf, 0, 1);
                if (n <= 0) return null;
                head.WriteByte(buf[0]);
                if ((matched == 0 || matched == 2) && buf[0] == (byte)'\r') matched++;
                else if ((matched == 1 || matched == 3) && buf[0] == (byte)'\n') matched++;
                else matched = 0;
                if (head.Length > 64 * 1024) return null;
            }

            var text = Encoding.UTF8.GetString(head.ToArray());
            var lines = text.Split(new[] { "\r\n" }, StringSplitOptions.None);
            if (lines.Length == 0) return null;

            var parts = lines[0].Split(' ');
            if (parts.Length < 2) return null;

            var req = new HttpRequest { Method = parts[0] };
            var target = parts[1];

            var q = target.IndexOf('?');
            if (q >= 0)
            {
                req.Path = target.Substring(0, q);
                foreach (var pair in target.Substring(q + 1).Split('&'))
                {
                    if (pair.Length == 0) continue;
                    var eq = pair.IndexOf('=');
                    if (eq < 0) req.Query[Uri.UnescapeDataString(pair)] = "";
                    else req.Query[Uri.UnescapeDataString(pair.Substring(0, eq))] =
                             Uri.UnescapeDataString(pair.Substring(eq + 1));
                }
            }
            else req.Path = target;

            for (int i = 1; i < lines.Length; i++)
            {
                var line = lines[i];
                if (line.Length == 0) continue;
                var c = line.IndexOf(':');
                if (c > 0) req.Headers[line.Substring(0, c).Trim()] = line.Substring(c + 1).Trim();
            }

            string cl;
            if (req.Headers.TryGetValue("Content-Length", out cl))
            {
                int len;
                if (int.TryParse(cl, out len) && len > 0)
                {
                    if (len > 16 * 1024 * 1024) return null;
                    var body = new byte[len];
                    int got = 0;
                    while (got < len)
                    {
                        int n = stream.Read(body, got, len - got);
                        if (n <= 0) break;
                        got += n;
                    }
                    req.Body = Encoding.UTF8.GetString(body, 0, got);
                }
            }

            return req;
        }

        static void WriteResponse(NetworkStream stream, HttpResponse resp)
        {
            var bodyBytes = string.IsNullOrEmpty(resp.Body) ? new byte[0] : Encoding.UTF8.GetBytes(resp.Body);

            var sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(resp.Status).Append(' ').Append(StatusText(resp.Status)).Append("\r\n");
            if (bodyBytes.Length > 0) sb.Append("Content-Type: ").Append(resp.ContentType).Append("\r\n");
            sb.Append("Content-Length: ").Append(bodyBytes.Length).Append("\r\n");
            sb.Append("Cache-Control: no-store\r\n");
            sb.Append("Connection: close\r\n\r\n");

            var headBytes = Encoding.ASCII.GetBytes(sb.ToString());
            stream.Write(headBytes, 0, headBytes.Length);
            if (bodyBytes.Length > 0) stream.Write(bodyBytes, 0, bodyBytes.Length);
            stream.Flush();
        }

        static string StatusText(int s)
        {
            switch (s)
            {
                case 200: return "OK";
                case 204: return "No Content";
                case 400: return "Bad Request";
                case 404: return "Not Found";
                case 405: return "Method Not Allowed";
                case 500: return "Internal Server Error";
                default: return "Status";
            }
        }

        public void Dispose()
        {
            _running = false;
            try { if (_listener != null) _listener.Stop(); } catch { }
            try { if (_accept != null) _accept.Join(500); } catch { }
        }
    }
}
