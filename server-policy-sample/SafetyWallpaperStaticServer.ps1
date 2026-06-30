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
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

public sealed class SafetyWallpaperStaticServerRuntime
{
    private readonly string rootPath;
    private readonly int port;
    private readonly int maxImageDownloads;
    private readonly SemaphoreSlim imageSemaphore;
    private readonly HttpListener listener;

    public SafetyWallpaperStaticServerRuntime(string rootPath, int port, int maxImageDownloads)
    {
        this.rootPath = Path.GetFullPath(rootPath);
        this.port = port;
        this.maxImageDownloads = Math.Max(1, maxImageDownloads);
        this.imageSemaphore = new SemaphoreSlim(this.maxImageDownloads, this.maxImageDownloads);
        this.listener = new HttpListener();
        this.listener.Prefixes.Add("http://+:" + this.port + "/");
    }

    public void Start()
    {
        this.listener.Start();
        Console.WriteLine("Safety wallpaper policy server started.");
        Console.WriteLine("URL: http://172.16.19.35:" + this.port + "/safety-wallpaper/policy.json");
        Console.WriteLine("Root: " + this.rootPath);
        Console.WriteLine("Max image downloads: " + this.maxImageDownloads);
        Console.WriteLine("Press Ctrl+C to stop.");

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
            string requestPath = Uri.UnescapeDataString(context.Request.Url.AbsolutePath.TrimStart('/'));

            if (requestPath.Length == 0)
            {
                requestPath = "safety-wallpaper/policy.json";
            }

            if (!requestPath.StartsWith("safety-wallpaper/", StringComparison.OrdinalIgnoreCase))
            {
                SendText(context.Response, 404, "Not found");
                return;
            }

            string relativePath = requestPath.Substring("safety-wallpaper/".Length).Replace('/', Path.DirectorySeparatorChar);
            string fullPath = Path.GetFullPath(Path.Combine(this.rootPath, relativePath));

            if (!fullPath.StartsWith(this.rootPath, StringComparison.OrdinalIgnoreCase))
            {
                SendText(context.Response, 403, "Forbidden");
                return;
            }

            if (!File.Exists(fullPath))
            {
                SendText(context.Response, 404, "Not found");
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
                SendText(context.Response, 500, "Server error: " + ex.Message);
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

    private static bool IsImageFile(string path)
    {
        string extension = Path.GetExtension(path).ToLowerInvariant();
        return extension == ".png" ||
               extension == ".jpg" ||
               extension == ".jpeg" ||
               extension == ".bmp" ||
               extension == ".gif";
    }

    private static string GetContentType(string path)
    {
        switch (Path.GetExtension(path).ToLowerInvariant())
        {
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
            default:
                return "application/octet-stream";
        }
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
