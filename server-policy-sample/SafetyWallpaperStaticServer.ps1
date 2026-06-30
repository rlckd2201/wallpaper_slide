param(
    [string]$Root = $PSScriptRoot,
    [int]$Port = 28080,
    [int]$MaxImageDownloads = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = (Resolve-Path -LiteralPath $Root).Path

Add-Type @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

public sealed class SafetyWallpaperStaticServerRuntime
{
    private readonly string rootPath;
    private readonly string policyPath;
    private readonly string imagesPath;
    private readonly int port;
    private readonly int maxImageDownloads;
    private readonly SemaphoreSlim imageSemaphore;
    private readonly HttpListener listener;

    public SafetyWallpaperStaticServerRuntime(string rootPath, int port, int maxImageDownloads)
    {
        this.rootPath = Path.GetFullPath(rootPath);
        this.policyPath = Path.Combine(this.rootPath, "policy.json");
        this.imagesPath = Path.Combine(this.rootPath, "images");
        this.port = port;
        this.maxImageDownloads = Math.Max(1, maxImageDownloads);
        this.imageSemaphore = new SemaphoreSlim(this.maxImageDownloads, this.maxImageDownloads);
        this.listener = new HttpListener();
        this.listener.Prefixes.Add("http://+:" + this.port + "/");
        Directory.CreateDirectory(this.imagesPath);
    }

    public void Start()
    {
        this.listener.Start();
        Console.WriteLine("\uc548\uc804 \ubc30\uacbd\ud654\uba74 \uc6f9\uc11c\ubc84\uac00 \uc2dc\uc791\ub418\uc5c8\uc2b5\ub2c8\ub2e4.");
        Console.WriteLine("\uad00\ub9ac\uc790 \ud398\uc774\uc9c0: http://172.16.19.35:" + this.port + "/safety-wallpaper/admin");
        Console.WriteLine("\uc815\ucc45 \uc8fc\uc18c: http://172.16.19.35:" + this.port + "/safety-wallpaper/policy.json");
        Console.WriteLine("\uc11c\ubc84 \ud3f4\ub354: " + this.rootPath);
        Console.WriteLine("\uc774\ubbf8\uc9c0 \ub2e4\uc6b4\ub85c\ub4dc \ub3d9\uc2dc \ucc98\ub9ac: \ucd5c\ub300 " + this.maxImageDownloads + "\uba85");
        Console.WriteLine("\uc885\ub8cc\ud558\ub824\uba74 Ctrl+C\ub97c \ub204\ub974\uc138\uc694.");

        while (this.listener.IsListening)
        {
            HttpListenerContext context = this.listener.GetContext();
            ThreadPool.QueueUserWorkItem(delegate { HandleRequest(context); });
        }
    }

    private void HandleRequest(HttpListenerContext context)
    {
        bool imageSlotAcquired = false;

        try
        {
            string method = context.Request.HttpMethod.ToUpperInvariant();
            string requestPath = Uri.UnescapeDataString(context.Request.Url.AbsolutePath.TrimStart('/'));

            if (requestPath.Length == 0)
            {
                requestPath = "safety-wallpaper/admin";
            }

            if (!requestPath.StartsWith("safety-wallpaper/", StringComparison.OrdinalIgnoreCase))
            {
                SendText(context.Response, 404, "\ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");
                return;
            }

            string route = requestPath.Substring("safety-wallpaper/".Length);

            if (method == "GET" && (route == "admin" || route == "admin/" || route == "admin.html"))
            {
                SendFile(context.Response, Path.Combine(this.rootPath, "admin.html"));
                return;
            }

            if (method == "GET" && route == "api/policy")
            {
                SendFile(context.Response, this.policyPath);
                return;
            }

            if (method == "GET" && route == "api/images")
            {
                SendJson(context.Response, BuildImageListJson());
                return;
            }

            if (method == "POST" && route == "api/policy")
            {
                SavePolicy(context.Request);
                SendJson(context.Response, "{\"ok\":true}");
                return;
            }

            if (method == "POST" && route == "api/upload")
            {
                string savedUrl = SaveUploadedImage(context.Request);
                SendJson(context.Response, "{\"ok\":true,\"url\":\"" + EscapeJson(savedUrl) + "\"}");
                return;
            }

            string relativePath = route.Replace('/', Path.DirectorySeparatorChar);
            string fullPath = Path.GetFullPath(Path.Combine(this.rootPath, relativePath));

            if (!IsPathUnderRoot(fullPath, this.rootPath))
            {
                SendText(context.Response, 403, "\ud5c8\uc6a9\ub418\uc9c0 \uc54a\uc740 \uacbd\ub85c\uc785\ub2c8\ub2e4.");
                return;
            }

            if (!File.Exists(fullPath))
            {
                SendText(context.Response, 404, "\ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");
                return;
            }

            bool isImage = IsImageFile(fullPath);

            if (isImage)
            {
                this.imageSemaphore.Wait();
                imageSlotAcquired = true;
            }

            SendFile(context.Response, fullPath);
        }
        catch (Exception ex)
        {
            try
            {
                SendText(context.Response, 500, "\uc11c\ubc84 \uc624\ub958: " + ex.Message);
            }
            catch
            {
            }
        }
        finally
        {
            if (imageSlotAcquired)
            {
                this.imageSemaphore.Release();
            }

            try
            {
                context.Response.Close();
            }
            catch
            {
            }
        }
    }

    private void SavePolicy(HttpListenerRequest request)
    {
        using (StreamReader reader = new StreamReader(request.InputStream, Encoding.UTF8))
        {
            string body = reader.ReadToEnd();

            if (String.IsNullOrWhiteSpace(body))
            {
                throw new InvalidOperationException("\uc815\ucc45 \ub0b4\uc6a9\uc774 \ube44\uc5b4 \uc788\uc2b5\ub2c8\ub2e4.");
            }

            File.WriteAllText(this.policyPath, body, new UTF8Encoding(false));
        }
    }

    private string SaveUploadedImage(HttpListenerRequest request)
    {
        string rawName = request.QueryString["name"];

        if (String.IsNullOrWhiteSpace(rawName))
        {
            throw new InvalidOperationException("\uc5c5\ub85c\ub4dc \ud30c\uc77c\uba85\uc774 \uc5c6\uc2b5\ub2c8\ub2e4.");
        }

        string fileName = SanitizeFileName(Uri.UnescapeDataString(rawName));
        string extension = Path.GetExtension(fileName).ToLowerInvariant();

        if (!IsAllowedImageExtension(extension))
        {
            throw new InvalidOperationException("png, jpg, jpeg, bmp, gif \ud30c\uc77c\ub9cc \uc5c5\ub85c\ub4dc\ud560 \uc218 \uc788\uc2b5\ub2c8\ub2e4.");
        }

        string destinationPath = Path.Combine(this.imagesPath, fileName);

        using (FileStream output = File.Create(destinationPath))
        {
            request.InputStream.CopyTo(output);
        }

        return "images/" + fileName;
    }

    private static bool IsPathUnderRoot(string fullPath, string rootPath)
    {
        string normalizedRoot = rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        return fullPath.StartsWith(normalizedRoot, StringComparison.OrdinalIgnoreCase);
    }

    private string BuildImageListJson()
    {
        Directory.CreateDirectory(this.imagesPath);

        StringBuilder builder = new StringBuilder();
        builder.Append("{\"images\":[");

        bool first = true;

        foreach (string path in Directory.GetFiles(this.imagesPath))
        {
            if (!IsImageFile(path))
            {
                continue;
            }

            FileInfo info = new FileInfo(path);

            if (!first)
            {
                builder.Append(",");
            }

            first = false;
            builder.Append("{");
            builder.Append("\"name\":\"").Append(EscapeJson(info.Name)).Append("\",");
            builder.Append("\"url\":\"images/").Append(EscapeJson(info.Name)).Append("\",");
            builder.Append("\"size\":").Append(info.Length).Append(",");
            builder.Append("\"version\":\"").Append(EscapeJson(info.LastWriteTimeUtc.Ticks.ToString())).Append("\",");
            builder.Append("\"modified\":\"").Append(EscapeJson(info.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"))).Append("\"");
            builder.Append("}");
        }

        builder.Append("]}");
        return builder.ToString();
    }

    private static string SanitizeFileName(string fileName)
    {
        string name = Path.GetFileName(fileName);

        foreach (char invalid in Path.GetInvalidFileNameChars())
        {
            name = name.Replace(invalid, '_');
        }

        if (String.IsNullOrWhiteSpace(name))
        {
            name = "image_" + DateTime.Now.ToString("yyyyMMddHHmmss") + ".png";
        }

        return name;
    }

    private static bool IsAllowedImageExtension(string extension)
    {
        return extension == ".png" ||
               extension == ".jpg" ||
               extension == ".jpeg" ||
               extension == ".bmp" ||
               extension == ".gif";
    }

    private static bool IsImageFile(string path)
    {
        return IsAllowedImageExtension(Path.GetExtension(path).ToLowerInvariant());
    }

    private static string GetContentType(string path)
    {
        switch (Path.GetExtension(path).ToLowerInvariant())
        {
            case ".html":
                return "text/html; charset=utf-8";
            case ".json":
                return "application/json; charset=utf-8";
            case ".png":
                return "image/png";
            case ".jpg":
            case ".jpeg":
                return "image/jpeg";
            case ".bmp":
                return "image/bmp";
            case ".gif":
                return "image/gif";
            case ".css":
                return "text/css; charset=utf-8";
            case ".js":
                return "application/javascript; charset=utf-8";
            default:
                return "application/octet-stream";
        }
    }

    private static string EscapeJson(string value)
    {
        if (value == null)
        {
            return "";
        }

        return value.Replace("\\", "\\\\")
                    .Replace("\"", "\\\"")
                    .Replace("\r", "\\r")
                    .Replace("\n", "\\n")
                    .Replace("\t", "\\t");
    }

    private static void SendJson(HttpListenerResponse response, string json)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        response.StatusCode = 200;
        response.ContentType = "application/json; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes, 0, bytes.Length);
    }

    private static void SendText(HttpListenerResponse response, int statusCode, string text)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(text);
        response.StatusCode = statusCode;
        response.ContentType = "text/plain; charset=utf-8";
        response.ContentLength64 = bytes.Length;
        response.OutputStream.Write(bytes, 0, bytes.Length);
    }

    private static void SendFile(HttpListenerResponse response, string path)
    {
        if (!File.Exists(path))
        {
            SendText(response, 404, "\ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");
            return;
        }

        response.StatusCode = 200;
        response.ContentType = GetContentType(path);

        using (FileStream stream = File.OpenRead(path))
        {
            response.ContentLength64 = stream.Length;
            byte[] buffer = new byte[64 * 1024];
            int read;

            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                response.OutputStream.Write(buffer, 0, read);
            }
        }
    }
}
'@

$server = [SafetyWallpaperStaticServerRuntime]::new($RootPath, $Port, $MaxImageDownloads)
$server.Start()
