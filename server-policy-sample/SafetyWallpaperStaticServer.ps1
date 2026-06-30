param(
    [string]$Root = $PSScriptRoot,
    [int]$Port = 28080,
    [int]$MaxImageDownloads = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RootPath = (Resolve-Path -LiteralPath $Root).Path

Add-Type -ReferencedAssemblies "System.Web.Extensions.dll" -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class AdminUsersFile
{
    public List<AdminUserRecord> users { get; set; }
}

public sealed class AdminUserRecord
{
    public string id { get; set; }
    public string name { get; set; }
    public string title { get; set; }
    public string email { get; set; }
    public bool enabled { get; set; }
    public bool mustChangePassword { get; set; }
    public string passwordHash { get; set; }
    public string lastPasswordChange { get; set; }
}

public sealed class AdminSessionRecord
{
    public string Token;
    public string UserId;
    public DateTime ExpiresUtc;
}

public sealed class LoginRequest
{
    public string id { get; set; }
    public string password { get; set; }
}

public sealed class ChangePasswordRequest
{
    public string currentPassword { get; set; }
    public string newPassword { get; set; }
}

public sealed class SafetyWallpaperStaticServerRuntime
{
    private const string SessionCookieName = "SafetyWallpaperAdminSession";
    private readonly string rootPath;
    private readonly string policyPath;
    private readonly string imagesPath;
    private readonly string adminUsersPath;
    private readonly string adminUsersTemplatePath;
    private readonly int port;
    private readonly int maxImageDownloads;
    private readonly SemaphoreSlim imageSemaphore;
    private readonly HttpListener listener;
    private readonly object authLock = new object();
    private readonly Dictionary<string, AdminUserRecord> adminUsers = new Dictionary<string, AdminUserRecord>(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, AdminSessionRecord> sessions = new Dictionary<string, AdminSessionRecord>(StringComparer.Ordinal);

    public SafetyWallpaperStaticServerRuntime(string rootPath, int port, int maxImageDownloads)
    {
        this.rootPath = Path.GetFullPath(rootPath);
        this.policyPath = Path.Combine(this.rootPath, "policy.json");
        this.imagesPath = Path.Combine(this.rootPath, "images");
        this.adminUsersPath = Path.Combine(this.rootPath, "admin-users.json");
        this.adminUsersTemplatePath = Path.Combine(this.rootPath, "admin-users.sample.json");
        this.port = port;
        this.maxImageDownloads = Math.Max(1, maxImageDownloads);
        this.imageSemaphore = new SemaphoreSlim(this.maxImageDownloads, this.maxImageDownloads);
        this.listener = new HttpListener();
        this.listener.Prefixes.Add("http://+:" + this.port + "/");
        Directory.CreateDirectory(this.imagesPath);
        EnsureAdminUsersFile();
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

            if (method == "GET" && route == "api/session")
            {
                SendSession(context);
                return;
            }

            if (method == "POST" && route == "api/login")
            {
                HandleLogin(context);
                return;
            }

            if (method == "POST" && route == "api/logout")
            {
                HandleLogout(context);
                return;
            }

            if (method == "POST" && route == "api/change-password")
            {
                HandleChangePassword(context);
                return;
            }

            if (route.StartsWith("api/", StringComparison.OrdinalIgnoreCase))
            {
                AdminUserRecord currentUser = RequireAdminUser(context);

                if (currentUser == null)
                {
                    return;
                }

                if (currentUser.mustChangePassword)
                {
                    SendJson(context.Response, 403, "{\"ok\":false,\"mustChangePassword\":true,\"message\":\"password_change_required\"}");
                    return;
                }
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

    private void EnsureAdminUsersFile()
    {
        if (!File.Exists(this.adminUsersPath))
        {
            if (!File.Exists(this.adminUsersTemplatePath))
            {
                throw new FileNotFoundException("admin-users.sample.json is missing.", this.adminUsersTemplatePath);
            }

            File.Copy(this.adminUsersTemplatePath, this.adminUsersPath);
        }

        LoadAdminUsers();
    }

    private void LoadAdminUsers()
    {
        lock (this.authLock)
        {
            string text = File.ReadAllText(this.adminUsersPath, Encoding.UTF8);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            AdminUsersFile file = serializer.Deserialize<AdminUsersFile>(text);

            this.adminUsers.Clear();

            if (file == null || file.users == null)
            {
                return;
            }

            foreach (AdminUserRecord user in file.users)
            {
                if (user == null || String.IsNullOrWhiteSpace(user.id))
                {
                    continue;
                }

                this.adminUsers[NormalizeAdminId(user.id)] = user;
            }
        }
    }

    private void SaveAdminUsersLocked()
    {
        AdminUsersFile file = new AdminUsersFile();
        file.users = new List<AdminUserRecord>();

        foreach (AdminUserRecord user in this.adminUsers.Values)
        {
            file.users.Add(user);
        }

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        string json = serializer.Serialize(file);
        File.WriteAllText(this.adminUsersPath, json, new UTF8Encoding(false));
    }

    private void SendSession(HttpListenerContext context)
    {
        AdminUserRecord user = GetCurrentUser(context.Request);

        if (user == null)
        {
            SendJson(context.Response, "{\"authenticated\":false}");
            return;
        }

        SendJson(context.Response, BuildSessionJson(user));
    }

    private void HandleLogin(HttpListenerContext context)
    {
        LoginRequest request = ReadJsonBody<LoginRequest>(context.Request);
        string userId = NormalizeAdminId(request == null ? null : request.id);
        string password = request == null ? null : request.password;
        AdminUserRecord user = null;

        lock (this.authLock)
        {
            this.adminUsers.TryGetValue(userId, out user);
        }

        if (user == null || !user.enabled || !VerifyPassword(password, user.passwordHash))
        {
            SendJson(context.Response, 401, "{\"ok\":false,\"message\":\"invalid_login\"}");
            return;
        }

        string token = CreateSession(user.id);
        SetSessionCookie(context.Response, token);
        SendJson(context.Response, "{\"ok\":true,\"mustChangePassword\":" + JsonBool(user.mustChangePassword) + ",\"user\":" + BuildUserJson(user) + "}");
    }

    private void HandleLogout(HttpListenerContext context)
    {
        string token = GetCookie(context.Request, SessionCookieName);

        if (!String.IsNullOrEmpty(token))
        {
            lock (this.authLock)
            {
                this.sessions.Remove(token);
            }
        }

        ClearSessionCookie(context.Response);
        SendJson(context.Response, "{\"ok\":true}");
    }

    private void HandleChangePassword(HttpListenerContext context)
    {
        AdminSessionRecord session = GetCurrentSession(context.Request);

        if (session == null)
        {
            SendJson(context.Response, 401, "{\"ok\":false,\"message\":\"login_required\"}");
            return;
        }

        ChangePasswordRequest request = ReadJsonBody<ChangePasswordRequest>(context.Request);
        string currentPassword = request == null ? null : request.currentPassword;
        string newPassword = request == null ? null : request.newPassword;

        lock (this.authLock)
        {
            AdminUserRecord user;

            if (!this.adminUsers.TryGetValue(NormalizeAdminId(session.UserId), out user) || user == null || !user.enabled)
            {
                SendJson(context.Response, 401, "{\"ok\":false,\"message\":\"login_required\"}");
                return;
            }

            if (!VerifyPassword(currentPassword, user.passwordHash))
            {
                SendJson(context.Response, 400, "{\"ok\":false,\"message\":\"current_password_invalid\"}");
                return;
            }

            if (!IsValidNewPassword(newPassword))
            {
                SendJson(context.Response, 400, "{\"ok\":false,\"message\":\"weak_password\"}");
                return;
            }

            if (VerifyPassword(newPassword, user.passwordHash))
            {
                SendJson(context.Response, 400, "{\"ok\":false,\"message\":\"same_password\"}");
                return;
            }

            user.passwordHash = HashPassword(newPassword);
            user.mustChangePassword = false;
            user.lastPasswordChange = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
            SaveAdminUsersLocked();
            SendJson(context.Response, "{\"ok\":true,\"mustChangePassword\":false,\"user\":" + BuildUserJson(user) + "}");
        }
    }

    private AdminUserRecord RequireAdminUser(HttpListenerContext context)
    {
        AdminUserRecord user = GetCurrentUser(context.Request);

        if (user == null)
        {
            SendJson(context.Response, 401, "{\"ok\":false,\"message\":\"login_required\"}");
            return null;
        }

        return user;
    }

    private AdminUserRecord GetCurrentUser(HttpListenerRequest request)
    {
        AdminSessionRecord session = GetCurrentSession(request);

        if (session == null)
        {
            return null;
        }

        lock (this.authLock)
        {
            AdminUserRecord user;

            if (this.adminUsers.TryGetValue(NormalizeAdminId(session.UserId), out user) && user != null && user.enabled)
            {
                return user;
            }
        }

        return null;
    }

    private AdminSessionRecord GetCurrentSession(HttpListenerRequest request)
    {
        string token = GetCookie(request, SessionCookieName);

        if (String.IsNullOrEmpty(token))
        {
            return null;
        }

        lock (this.authLock)
        {
            AdminSessionRecord session;

            if (!this.sessions.TryGetValue(token, out session))
            {
                return null;
            }

            if (session.ExpiresUtc <= DateTime.UtcNow)
            {
                this.sessions.Remove(token);
                return null;
            }

            return session;
        }
    }

    private string CreateSession(string userId)
    {
        byte[] bytes = new byte[32];

        using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
        {
            rng.GetBytes(bytes);
        }

        string token = Convert.ToBase64String(bytes).Replace("+", "-").Replace("/", "_").TrimEnd('=');

        lock (this.authLock)
        {
            this.sessions[token] = new AdminSessionRecord
            {
                Token = token,
                UserId = userId,
                ExpiresUtc = DateTime.UtcNow.AddHours(8)
            };
        }

        return token;
    }

    private static T ReadJsonBody<T>(HttpListenerRequest request)
    {
        using (StreamReader reader = new StreamReader(request.InputStream, Encoding.UTF8))
        {
            string body = reader.ReadToEnd();

            if (String.IsNullOrWhiteSpace(body))
            {
                return default(T);
            }

            JavaScriptSerializer serializer = new JavaScriptSerializer();
            return serializer.Deserialize<T>(body);
        }
    }

    private static string BuildSessionJson(AdminUserRecord user)
    {
        return "{\"authenticated\":true,\"mustChangePassword\":" + JsonBool(user.mustChangePassword) + ",\"user\":" + BuildUserJson(user) + "}";
    }

    private static string BuildUserJson(AdminUserRecord user)
    {
        return "{\"id\":\"" + EscapeJson(user.id) + "\"," +
               "\"name\":\"" + EscapeJson(user.name) + "\"," +
               "\"title\":\"" + EscapeJson(user.title) + "\"," +
               "\"email\":\"" + EscapeJson(user.email) + "\"}";
    }

    private static string GetCookie(HttpListenerRequest request, string name)
    {
        if (request == null || request.Cookies == null)
        {
            return null;
        }

        Cookie cookie = request.Cookies[name];
        return cookie == null ? null : cookie.Value;
    }

    private static void SetSessionCookie(HttpListenerResponse response, string token)
    {
        response.Headers.Add("Set-Cookie", SessionCookieName + "=" + token + "; Path=/safety-wallpaper; HttpOnly; SameSite=Lax");
    }

    private static void ClearSessionCookie(HttpListenerResponse response)
    {
        response.Headers.Add("Set-Cookie", SessionCookieName + "=; Path=/safety-wallpaper; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax");
    }

    private static string NormalizeAdminId(string value)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return "";
        }

        string result = value.Trim();
        int at = result.IndexOf('@');

        if (at > 0)
        {
            result = result.Substring(0, at);
        }

        return result;
    }

    private static bool IsValidNewPassword(string password)
    {
        return !String.IsNullOrEmpty(password) && password.Length >= 8;
    }

    private static string HashPassword(string password)
    {
        byte[] salt = new byte[16];

        using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
        {
            rng.GetBytes(salt);
        }

        int iterations = 120000;
        byte[] hash;

        using (Rfc2898DeriveBytes pbkdf2 = new Rfc2898DeriveBytes(password, salt, iterations))
        {
            hash = pbkdf2.GetBytes(32);
        }

        return "pbkdf2-sha1:" + iterations + ":" + Convert.ToBase64String(salt) + ":" + Convert.ToBase64String(hash);
    }

    private static bool VerifyPassword(string password, string passwordHash)
    {
        if (String.IsNullOrEmpty(password) || String.IsNullOrEmpty(passwordHash))
        {
            return false;
        }

        string[] parts = passwordHash.Split(':');

        if (parts.Length != 4 || parts[0] != "pbkdf2-sha1")
        {
            return false;
        }

        int iterations;

        if (!Int32.TryParse(parts[1], out iterations))
        {
            return false;
        }

        byte[] salt = Convert.FromBase64String(parts[2]);
        byte[] expected = Convert.FromBase64String(parts[3]);
        byte[] actual;

        using (Rfc2898DeriveBytes pbkdf2 = new Rfc2898DeriveBytes(password, salt, iterations))
        {
            actual = pbkdf2.GetBytes(expected.Length);
        }

        return FixedTimeEquals(actual, expected);
    }

    private static bool FixedTimeEquals(byte[] a, byte[] b)
    {
        if (a == null || b == null)
        {
            return false;
        }

        int diff = a.Length ^ b.Length;
        int length = Math.Min(a.Length, b.Length);

        for (int i = 0; i < length; i++)
        {
            diff |= a[i] ^ b[i];
        }

        return diff == 0;
    }

    private static string JsonBool(bool value)
    {
        return value ? "true" : "false";
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
        SendJson(response, 200, json);
    }

    private static void SendJson(HttpListenerResponse response, int statusCode, string json)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(json);
        response.StatusCode = statusCode;
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
