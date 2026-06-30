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
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Mail;
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
    public string role { get; set; }
    public bool enabled { get; set; }
    public bool? active { get; set; }
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

public sealed class ForgotPasswordRequest
{
    public string user_id { get; set; }
    public string userId { get; set; }
    public string id { get; set; }
}

public sealed class MailSettings
{
    public string host { get; set; }
    public int port { get; set; }
    public bool enableSsl { get; set; }
    public string username { get; set; }
    public string password { get; set; }
    public string fromEmail { get; set; }
    public string fromName { get; set; }
    public int timeoutMilliseconds { get; set; }
}

public sealed class AdminUserUpsertRequest
{
    public string id { get; set; }
    public string name { get; set; }
    public string title { get; set; }
    public string email { get; set; }
    public string role { get; set; }
    public bool active { get; set; }
    public string password { get; set; }
}

public sealed class ImageDownloadQueueItem
{
    public long id;
    public string ip;
    public string computer;
    public string user;
    public string path;
    public string agent;
    public string userAgent;
    public string status;
    public DateTime requestedAt;
    public DateTime startedAt;
    public DateTime completedAt;
    public long durationMilliseconds;
}

public sealed class SafetyWallpaperStaticServerRuntime
{
    private const string SessionCookieName = "SafetyWallpaperAdminSession";
    private const int CompletedImageHistoryLimit = 200;
    private readonly string rootPath;
    private readonly string policyPath;
    private readonly string imagesPath;
    private readonly string adminUsersPath;
    private readonly string adminUsersTemplatePath;
    private readonly string mailSettingsPath;
    private readonly string logsPath;
    private readonly string auditLogPath;
    private readonly string accessLogPath;
    private readonly string clientDownloadLogPath;
    private readonly int port;
    private readonly int maxImageDownloads;
    private readonly SemaphoreSlim imageSemaphore;
    private readonly HttpListener listener;
    private readonly object authLock = new object();
    private readonly object logLock = new object();
    private readonly object imageQueueLock = new object();
    private readonly Dictionary<string, AdminUserRecord> adminUsers = new Dictionary<string, AdminUserRecord>(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, AdminSessionRecord> sessions = new Dictionary<string, AdminSessionRecord>(StringComparer.Ordinal);
    private readonly Dictionary<long, ImageDownloadQueueItem> imageQueueItems = new Dictionary<long, ImageDownloadQueueItem>();
    private readonly List<ImageDownloadQueueItem> imageCompletedItems = new List<ImageDownloadQueueItem>();
    private int imageDownloadsActive = 0;
    private int imageDownloadsWaiting = 0;
    private long imageDownloadRequestSequence = 0;
    private long imageDownloadRequestsTotal = 0;
    private long imageDownloadsCompletedTotal = 0;

    public SafetyWallpaperStaticServerRuntime(string rootPath, int port, int maxImageDownloads)
    {
        this.rootPath = Path.GetFullPath(rootPath);
        this.policyPath = Path.Combine(this.rootPath, "policy.json");
        this.imagesPath = Path.Combine(this.rootPath, "images");
        this.adminUsersPath = Path.Combine(this.rootPath, "admin-users.json");
        this.adminUsersTemplatePath = Path.Combine(this.rootPath, "admin-users.sample.json");
        this.mailSettingsPath = Path.Combine(this.rootPath, "mail-settings.json");
        this.logsPath = Path.Combine(this.rootPath, "logs");
        this.auditLogPath = Path.Combine(this.logsPath, "admin-audit.log");
        this.accessLogPath = Path.Combine(this.logsPath, "admin-access.log");
        this.clientDownloadLogPath = Path.Combine(this.logsPath, "client-download.log");
        this.port = port;
        this.maxImageDownloads = Math.Max(1, maxImageDownloads);
        this.imageSemaphore = new SemaphoreSlim(this.maxImageDownloads, this.maxImageDownloads);
        this.listener = new HttpListener();
        this.listener.Prefixes.Add("http://+:" + this.port + "/");
        Directory.CreateDirectory(this.imagesPath);
        Directory.CreateDirectory(this.logsPath);
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
        ImageDownloadQueueItem imageQueueItem = null;
        AdminUserRecord currentUser = null;

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

            if (method == "POST" && (route == "api/forgot-password" || route == "api/auth/forgot-password"))
            {
                HandleForgotPassword(context);
                return;
            }

            if (method == "POST" && route == "api/change-password")
            {
                HandleChangePassword(context);
                return;
            }

            if (route.StartsWith("api/", StringComparison.OrdinalIgnoreCase))
            {
                currentUser = RequireAdminUser(context);

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

            if (IsSuperAdminRoute(route) && !RequireSuperAdmin(context, currentUser))
            {
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

            if (method == "DELETE" && route == "api/images")
            {
                string deletedUrl = DeleteUploadedImage(context.Request);
                WriteAudit(currentUser, "image_delete", deletedUrl);
                SendJson(context.Response, "{\"ok\":true,\"url\":\"" + EscapeJson(deletedUrl) + "\"}");
                return;
            }

            if (method == "POST" && route == "api/policy")
            {
                SavePolicy(context.Request);
                WriteAudit(currentUser, "policy_save", "policy.json");
                SendJson(context.Response, "{\"ok\":true}");
                return;
            }

            if (method == "POST" && route == "api/upload")
            {
                string savedUrl = SaveUploadedImage(context.Request);
                WriteAudit(currentUser, "image_upload", savedUrl);
                SendJson(context.Response, "{\"ok\":true,\"url\":\"" + EscapeJson(savedUrl) + "\"}");
                return;
            }

            if (method == "GET" && route == "api/audit-log")
            {
                SendJson(context.Response, BuildLogJson(this.auditLogPath));
                return;
            }

            if (method == "GET" && route == "api/access-log")
            {
                SendJson(context.Response, BuildLogJson(this.accessLogPath));
                return;
            }

            if (method == "GET" && route == "api/client-download-log")
            {
                SendJson(context.Response, BuildLogJson(this.clientDownloadLogPath));
                return;
            }

            if (method == "GET" && route == "api/deployment-status")
            {
                SendJson(context.Response, BuildDeploymentStatusJson());
                return;
            }

            if (method == "GET" && route == "api/queue-status")
            {
                SendJson(context.Response, BuildQueueStatusJson());
                return;
            }

            if (method == "GET" && route == "api/admin-users")
            {
                SendJson(context.Response, BuildAdminUsersJson());
                return;
            }

            if (method == "POST" && route == "api/admin-users")
            {
                UpsertAdminUser(context.Request, currentUser, false, null);
                SendJson(context.Response, "{\"ok\":true}");
                return;
            }

            if (route.StartsWith("api/admin-users/", StringComparison.OrdinalIgnoreCase))
            {
                string targetId = NormalizeAdminId(route.Substring("api/admin-users/".Length));

                if (method == "PUT")
                {
                    UpsertAdminUser(context.Request, currentUser, true, targetId);
                    SendJson(context.Response, "{\"ok\":true}");
                    return;
                }

                if (method == "DELETE")
                {
                    DeleteAdminUser(targetId, currentUser);
                    SendJson(context.Response, "{\"ok\":true}");
                    return;
                }
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
            bool isPolicyDownload = String.Equals(route.Replace('\\', '/'), "policy.json", StringComparison.OrdinalIgnoreCase);

            if (method == "GET" && (isPolicyDownload || isImage))
            {
                WriteClientDownload(context.Request, isPolicyDownload ? "policy_check" : "image_download", route.Replace('\\', '/'));
            }

            if (isImage)
            {
                imageQueueItem = AcquireImageDownloadSlot(context.Request, route.Replace('\\', '/'));
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
                CompleteImageDownloadSlot(imageQueueItem);
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
        MergeSeedAdminUsers();
    }

    private void MergeSeedAdminUsers()
    {
        if (!File.Exists(this.adminUsersTemplatePath))
        {
            return;
        }

        string text = File.ReadAllText(this.adminUsersTemplatePath, Encoding.UTF8);
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        AdminUsersFile seedFile = serializer.Deserialize<AdminUsersFile>(text);

        if (seedFile == null || seedFile.users == null)
        {
            return;
        }

        bool changed = false;

        lock (this.authLock)
        {
            foreach (AdminUserRecord seedUser in seedFile.users)
            {
                if (seedUser == null || String.IsNullOrWhiteSpace(seedUser.id))
                {
                    continue;
                }

                string id = NormalizeAdminId(seedUser.id);
                AdminUserRecord existing;

                if (!this.adminUsers.TryGetValue(id, out existing))
                {
                    NormalizeAdminUser(seedUser);
                    this.adminUsers[id] = seedUser;
                    changed = true;
                    continue;
                }

                if (String.IsNullOrWhiteSpace(existing.role))
                {
                    existing.role = String.IsNullOrWhiteSpace(seedUser.role) ? "operator" : seedUser.role;
                    changed = true;
                }

                if (!existing.active.HasValue)
                {
                    existing.active = seedUser.active.HasValue ? seedUser.active : existing.enabled;
                    changed = true;
                }

                if (String.IsNullOrWhiteSpace(existing.email) && !String.IsNullOrWhiteSpace(seedUser.email))
                {
                    existing.email = seedUser.email;
                    changed = true;
                }
            }

            if (changed)
            {
                SaveAdminUsersLocked();
            }
        }
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

                NormalizeAdminUser(user);
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

        if (user == null || !IsUserActive(user) || !VerifyPassword(password, user.passwordHash))
        {
            WriteAccess(userId, "login_failed", context.Request.RemoteEndPoint == null ? "" : context.Request.RemoteEndPoint.ToString());
            SendJson(context.Response, 401, "{\"ok\":false,\"message\":\"invalid_login\"}");
            return;
        }

        string token = CreateSession(user.id);
        SetSessionCookie(context.Response, token);
        WriteAccess(user.id, "login_success", context.Request.RemoteEndPoint == null ? "" : context.Request.RemoteEndPoint.ToString());
        SendJson(context.Response, "{\"ok\":true,\"mustChangePassword\":" + JsonBool(user.mustChangePassword) + ",\"user\":" + BuildUserJson(user) + "}");
    }

    private void HandleLogout(HttpListenerContext context)
    {
        string token = GetCookie(context.Request, SessionCookieName);

        if (!String.IsNullOrEmpty(token))
        {
            lock (this.authLock)
            {
                AdminSessionRecord session;

                if (this.sessions.TryGetValue(token, out session))
                {
                    WriteAccess(session.UserId, "logout", context.Request.RemoteEndPoint == null ? "" : context.Request.RemoteEndPoint.ToString());
                    this.sessions.Remove(token);
                }
            }
        }

        ClearSessionCookie(context.Response);
        SendJson(context.Response, "{\"ok\":true}");
    }

    private void HandleForgotPassword(HttpListenerContext context)
    {
        ForgotPasswordRequest request = ReadJsonBody<ForgotPasswordRequest>(context.Request);
        string userId = NormalizeAdminId(FirstNonEmpty(
            request == null ? null : request.user_id,
            request == null ? null : request.userId,
            request == null ? null : request.id));

        AdminUserRecord user = null;

        lock (this.authLock)
        {
            this.adminUsers.TryGetValue(userId, out user);
        }

        if (user == null || !IsUserActive(user))
        {
            SendJson(context.Response, 404, "{\"ok\":false,\"message\":\"account_not_found\"}");
            return;
        }

        if (String.IsNullOrWhiteSpace(user.email))
        {
            SendJson(context.Response, 400, "{\"ok\":false,\"message\":\"email_missing\"}");
            return;
        }

        MailSettings mailSettings;

        try
        {
            mailSettings = LoadMailSettings();
        }
        catch
        {
            SendJson(context.Response, 500, "{\"ok\":false,\"message\":\"mail_settings_missing\"}");
            return;
        }

        string temporaryPassword = MakeTemporaryPassword(12);
        string oldHash;
        bool oldMustChangePassword;
        string oldLastPasswordChange;

        lock (this.authLock)
        {
            if (!this.adminUsers.TryGetValue(userId, out user) || user == null || !IsUserActive(user))
            {
                SendJson(context.Response, 404, "{\"ok\":false,\"message\":\"account_not_found\"}");
                return;
            }

            oldHash = user.passwordHash;
            oldMustChangePassword = user.mustChangePassword;
            oldLastPasswordChange = user.lastPasswordChange;

            user.passwordHash = HashPassword(temporaryPassword);
            user.mustChangePassword = true;
            user.lastPasswordChange = "";
            SaveAdminUsersLocked();
        }

        try
        {
            SendPasswordResetMail(mailSettings, user.email, user.id, temporaryPassword);
            WriteAudit(user, "password_reset", user.id);
            SendJson(context.Response, "{\"ok\":true}");
        }
        catch
        {
            lock (this.authLock)
            {
                AdminUserRecord rollbackUser;

                if (this.adminUsers.TryGetValue(userId, out rollbackUser) && rollbackUser != null)
                {
                    rollbackUser.passwordHash = oldHash;
                    rollbackUser.mustChangePassword = oldMustChangePassword;
                    rollbackUser.lastPasswordChange = oldLastPasswordChange;
                    SaveAdminUsersLocked();
                }
            }

            SendJson(context.Response, 500, "{\"ok\":false,\"message\":\"mail_send_failed\"}");
        }
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

            if (!this.adminUsers.TryGetValue(NormalizeAdminId(session.UserId), out user) || user == null || !IsUserActive(user))
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
            WriteAudit(user, "password_change", user.id);
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

    private static bool IsSuperAdminRoute(string route)
    {
        return route == "api/audit-log" ||
               route == "api/access-log" ||
               route == "api/client-download-log" ||
               route == "api/deployment-status" ||
               route == "api/queue-status" ||
               route == "api/admin-users" ||
               route.StartsWith("api/admin-users/", StringComparison.OrdinalIgnoreCase);
    }

    private bool RequireSuperAdmin(HttpListenerContext context, AdminUserRecord user)
    {
        if (!IsSuperAdmin(user))
        {
            SendJson(context.Response, 403, "{\"ok\":false,\"message\":\"super_admin_required\"}");
            return false;
        }

        return true;
    }

    private void UpsertAdminUser(HttpListenerRequest request, AdminUserRecord actor, bool isUpdate, string targetId)
    {
        AdminUserUpsertRequest body = ReadJsonBody<AdminUserUpsertRequest>(request);

        if (body == null)
        {
            throw new InvalidOperationException("admin user body is empty.");
        }

        string id = NormalizeAdminId(isUpdate ? targetId : body.id);

        if (String.IsNullOrWhiteSpace(id))
        {
            throw new InvalidOperationException("admin id is required.");
        }

        lock (this.authLock)
        {
            AdminUserRecord user;

            if (!this.adminUsers.TryGetValue(id, out user))
            {
                if (isUpdate)
                {
                    throw new InvalidOperationException("admin user not found.");
                }

                if (String.IsNullOrWhiteSpace(body.password))
                {
                    throw new InvalidOperationException("initial password is required.");
                }

                user = new AdminUserRecord();
                user.id = id;
                user.passwordHash = HashPassword(body.password);
                user.mustChangePassword = true;
                user.lastPasswordChange = "";
                this.adminUsers[id] = user;
            }
            else if (!isUpdate)
            {
                throw new InvalidOperationException("admin user already exists.");
            }
            else if (!String.IsNullOrWhiteSpace(body.password))
            {
                user.passwordHash = HashPassword(body.password);
                user.mustChangePassword = true;
                user.lastPasswordChange = "";
            }

            user.name = TrimOrEmpty(body.name);
            user.title = TrimOrEmpty(body.title);
            user.email = TrimOrEmpty(body.email);
            user.role = NormalizeRole(body.role);
            user.active = body.active;
            user.enabled = body.active;
            NormalizeAdminUser(user);
            SaveAdminUsersLocked();
        }

        WriteAudit(actor, isUpdate ? "admin_user_update" : "admin_user_create", id);
    }

    private void DeleteAdminUser(string targetId, AdminUserRecord actor)
    {
        string id = NormalizeAdminId(targetId);

        if (String.IsNullOrWhiteSpace(id))
        {
            throw new InvalidOperationException("admin id is required.");
        }

        if (actor != null && String.Equals(NormalizeAdminId(actor.id), id, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("cannot delete current user.");
        }

        lock (this.authLock)
        {
            if (!this.adminUsers.Remove(id))
            {
                throw new InvalidOperationException("admin user not found.");
            }

            SaveAdminUsersLocked();
        }

        WriteAudit(actor, "admin_user_delete", id);
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

            if (this.adminUsers.TryGetValue(NormalizeAdminId(session.UserId), out user) && user != null && IsUserActive(user))
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

    private MailSettings LoadMailSettings()
    {
        if (!File.Exists(this.mailSettingsPath))
        {
            throw new FileNotFoundException("mail-settings.json is missing.", this.mailSettingsPath);
        }

        string text = File.ReadAllText(this.mailSettingsPath, Encoding.UTF8);
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        MailSettings settings = serializer.Deserialize<MailSettings>(text);

        if (settings == null ||
            String.IsNullOrWhiteSpace(settings.host) ||
            String.IsNullOrWhiteSpace(settings.fromEmail))
        {
            throw new InvalidOperationException("mail-settings.json host/fromEmail is missing.");
        }

        if (settings.port <= 0)
        {
            settings.port = 25;
        }

        if (settings.timeoutMilliseconds <= 0)
        {
            settings.timeoutMilliseconds = 15000;
        }

        return settings;
    }

    private static void SendPasswordResetMail(MailSettings settings, string email, string userId, string temporaryPassword)
    {
        string fromName = String.IsNullOrWhiteSpace(settings.fromName) ? settings.fromEmail : settings.fromName;

        using (MailMessage message = new MailMessage())
        {
            message.From = new MailAddress(settings.fromEmail, fromName, Encoding.UTF8);
            message.To.Add(new MailAddress(email));
            message.Subject = "\uc548\uc804 \ubc30\uacbd\ud654\uba74 \uad00\ub9ac\uc790 \uc784\uc2dc \ube44\ubc00\ubc88\ud638";
            message.SubjectEncoding = Encoding.UTF8;
            message.Body = BuildPasswordResetMailBody(userId, temporaryPassword);
            message.BodyEncoding = Encoding.UTF8;

            using (SmtpClient client = new SmtpClient(settings.host, settings.port))
            {
                client.EnableSsl = settings.enableSsl;
                client.Timeout = settings.timeoutMilliseconds;

                if (!String.IsNullOrWhiteSpace(settings.username))
                {
                    client.Credentials = new NetworkCredential(settings.username, settings.password == null ? "" : settings.password);
                }

                client.Send(message);
            }
        }
    }

    private static string BuildPasswordResetMailBody(string userId, string temporaryPassword)
    {
        return userId + " \uacc4\uc815\uc758 \uc784\uc2dc \ube44\ubc00\ubc88\ud638\uac00 \ubc1c\uae09\ub418\uc5c8\uc2b5\ub2c8\ub2e4." + Environment.NewLine +
               Environment.NewLine +
               "\uc784\uc2dc \ube44\ubc00\ubc88\ud638: " + temporaryPassword + Environment.NewLine +
               Environment.NewLine +
               "\ub85c\uadf8\uc778 \ud6c4 \ubc18\ub4dc\uc2dc \uc0c8 \ube44\ubc00\ubc88\ud638\ub85c \ubcc0\uacbd\ud574 \uc8fc\uc138\uc694.";
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
               "\"email\":\"" + EscapeJson(user.email) + "\"," +
               "\"role\":\"" + EscapeJson(NormalizeRole(user.role)) + "\"," +
               "\"active\":" + JsonBool(IsUserActive(user)) + "}";
    }

    private string BuildAdminUsersJson()
    {
        StringBuilder builder = new StringBuilder();
        builder.Append("{\"users\":[");

        bool first = true;

        lock (this.authLock)
        {
            foreach (AdminUserRecord user in this.adminUsers.Values)
            {
                if (!first)
                {
                    builder.Append(",");
                }

                first = false;
                builder.Append("{");
                builder.Append("\"id\":\"").Append(EscapeJson(user.id)).Append("\",");
                builder.Append("\"name\":\"").Append(EscapeJson(user.name)).Append("\",");
                builder.Append("\"title\":\"").Append(EscapeJson(user.title)).Append("\",");
                builder.Append("\"email\":\"").Append(EscapeJson(user.email)).Append("\",");
                builder.Append("\"role\":\"").Append(EscapeJson(NormalizeRole(user.role))).Append("\",");
                builder.Append("\"active\":").Append(JsonBool(IsUserActive(user))).Append(",");
                builder.Append("\"mustChangePassword\":").Append(JsonBool(user.mustChangePassword)).Append(",");
                builder.Append("\"lastPasswordChange\":\"").Append(EscapeJson(user.lastPasswordChange)).Append("\"");
                builder.Append("}");
            }
        }

        builder.Append("]}");
        return builder.ToString();
    }

    private string BuildLogJson(string path)
    {
        StringBuilder builder = new StringBuilder();
        builder.Append("{\"items\":[");

        string[] lines = File.Exists(path) ? File.ReadAllLines(path, Encoding.UTF8) : new string[0];
        int start = Math.Max(0, lines.Length - 200);
        bool first = true;

        for (int i = lines.Length - 1; i >= start; i--)
        {
            if (String.IsNullOrWhiteSpace(lines[i]))
            {
                continue;
            }

            if (!first)
            {
                builder.Append(",");
            }

            first = false;
            builder.Append(lines[i]);
        }

        builder.Append("]}");
        return builder.ToString();
    }

    private string BuildDeploymentStatusJson()
    {
        int imageCount = 0;

        if (Directory.Exists(this.imagesPath))
        {
            foreach (string path in Directory.GetFiles(this.imagesPath))
            {
                if (IsImageFile(path))
                {
                    imageCount++;
                }
            }
        }

        string policyVersion = "";
        string enabled = "false";
        string campaignStart = "";
        string campaignEnd = "";
        int slideCount = 0;

        if (File.Exists(this.policyPath))
        {
            string text = File.ReadAllText(this.policyPath, Encoding.UTF8);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Dictionary<string, object> policy = serializer.Deserialize<Dictionary<string, object>>(text);

            if (policy != null)
            {
                policyVersion = GetDictionaryString(policy, "policyVersion");
                campaignStart = GetDictionaryString(policy, "campaignStart");
                campaignEnd = GetDictionaryString(policy, "campaignEnd");
                enabled = GetDictionaryBool(policy, "enabled") ? "true" : "false";

                object slidesObj;

                if (policy.TryGetValue("slides", out slidesObj) && slidesObj is ArrayList)
                {
                    slideCount = ((ArrayList)slidesObj).Count;
                }
            }
        }

        return "{\"serverTime\":\"" + EscapeJson(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")) + "\"," +
               "\"policyVersion\":\"" + EscapeJson(policyVersion) + "\"," +
               "\"enabled\":" + enabled + "," +
               "\"campaignStart\":\"" + EscapeJson(campaignStart) + "\"," +
               "\"campaignEnd\":\"" + EscapeJson(campaignEnd) + "\"," +
               "\"selectedSlides\":" + slideCount + "," +
               "\"uploadedImages\":" + imageCount + "}";
    }

    private string BuildQueueStatusJson()
    {
        int active = Math.Max(0, Volatile.Read(ref this.imageDownloadsActive));
        int waiting = Math.Max(0, Volatile.Read(ref this.imageDownloadsWaiting));
        long totalRequests = Math.Max(0, Interlocked.Read(ref this.imageDownloadRequestsTotal));
        long totalCompleted = Math.Max(0, Interlocked.Read(ref this.imageDownloadsCompletedTotal));
        StringBuilder builder = new StringBuilder();

        builder.Append("{\"serverTime\":\"").Append(EscapeJson(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss"))).Append("\",");
        builder.Append("\"maxImageDownloads\":").Append(this.maxImageDownloads).Append(",");
        builder.Append("\"activeImageDownloads\":").Append(active).Append(",");
        builder.Append("\"waitingImageDownloads\":").Append(waiting).Append(",");
        builder.Append("\"availableImageSlots\":").Append(Math.Max(0, this.maxImageDownloads - active)).Append(",");
        builder.Append("\"totalImageDownloadRequests\":").Append(totalRequests).Append(",");
        builder.Append("\"completedImageDownloads\":").Append(totalCompleted).Append(",");

        lock (this.imageQueueLock)
        {
            builder.Append("\"downloadingItems\":[");
            AppendQueueItemsByStatus(builder, "downloading");
            builder.Append("],\"waitingItems\":[");
            AppendQueueItemsByStatus(builder, "waiting");
            builder.Append("],\"completedItems\":[");
            AppendCompletedQueueItems(builder);
            builder.Append("]}");
        }

        return builder.ToString();
    }

    private ImageDownloadQueueItem AcquireImageDownloadSlot(HttpListenerRequest request, string path)
    {
        bool removedFromWaiting = false;
        ImageDownloadQueueItem item = CreateImageDownloadQueueItem(request, path);

        Interlocked.Increment(ref this.imageDownloadsWaiting);
        Interlocked.Increment(ref this.imageDownloadRequestsTotal);

        lock (this.imageQueueLock)
        {
            this.imageQueueItems[item.id] = item;
        }

        try
        {
            this.imageSemaphore.Wait();
            Interlocked.Decrement(ref this.imageDownloadsWaiting);
            removedFromWaiting = true;

            lock (this.imageQueueLock)
            {
                item.status = "downloading";
                item.startedAt = DateTime.Now;
            }

            Interlocked.Increment(ref this.imageDownloadsActive);
            return item;
        }
        catch
        {
            if (!removedFromWaiting)
            {
                Interlocked.Decrement(ref this.imageDownloadsWaiting);
            }

            lock (this.imageQueueLock)
            {
                this.imageQueueItems.Remove(item.id);
            }

            throw;
        }
    }

    private void CompleteImageDownloadSlot(ImageDownloadQueueItem item)
    {
        try
        {
            Interlocked.Decrement(ref this.imageDownloadsActive);
            Interlocked.Increment(ref this.imageDownloadsCompletedTotal);

            if (item != null)
            {
                lock (this.imageQueueLock)
                {
                    item.status = "completed";
                    item.completedAt = DateTime.Now;

                    if (item.startedAt != DateTime.MinValue)
                    {
                        item.durationMilliseconds = Math.Max(0, (long)(item.completedAt - item.startedAt).TotalMilliseconds);
                    }

                    this.imageQueueItems.Remove(item.id);
                    this.imageCompletedItems.Insert(0, item);

                    while (this.imageCompletedItems.Count > CompletedImageHistoryLimit)
                    {
                        this.imageCompletedItems.RemoveAt(this.imageCompletedItems.Count - 1);
                    }
                }
            }
        }
        finally
        {
            this.imageSemaphore.Release();
        }
    }

    private ImageDownloadQueueItem CreateImageDownloadQueueItem(HttpListenerRequest request, string path)
    {
        ImageDownloadQueueItem item = new ImageDownloadQueueItem();
        item.id = Interlocked.Increment(ref this.imageDownloadRequestSequence);
        item.ip = GetClientIp(request);
        item.computer = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-Computer"], "");
        item.user = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-User"], "");
        item.path = path;
        item.agent = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-Agent"], "");
        item.userAgent = FirstNonEmpty(request.UserAgent, "");
        item.status = "waiting";
        item.requestedAt = DateTime.Now;
        item.startedAt = DateTime.MinValue;
        item.completedAt = DateTime.MinValue;
        item.durationMilliseconds = 0;
        return item;
    }

    private void AppendQueueItemsByStatus(StringBuilder builder, string status)
    {
        bool first = true;

        foreach (KeyValuePair<long, ImageDownloadQueueItem> pair in this.imageQueueItems)
        {
            if (!String.Equals(pair.Value.status, status, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!first)
            {
                builder.Append(",");
            }

            first = false;
            AppendQueueItemJson(builder, pair.Value);
        }
    }

    private void AppendCompletedQueueItems(StringBuilder builder)
    {
        bool first = true;

        foreach (ImageDownloadQueueItem item in this.imageCompletedItems)
        {
            if (!first)
            {
                builder.Append(",");
            }

            first = false;
            AppendQueueItemJson(builder, item);
        }
    }

    private static void AppendQueueItemJson(StringBuilder builder, ImageDownloadQueueItem item)
    {
        builder.Append("{");
        builder.Append("\"id\":").Append(item.id).Append(",");
        builder.Append("\"ip\":\"").Append(EscapeJson(item.ip)).Append("\",");
        builder.Append("\"computer\":\"").Append(EscapeJson(item.computer)).Append("\",");
        builder.Append("\"user\":\"").Append(EscapeJson(item.user)).Append("\",");
        builder.Append("\"path\":\"").Append(EscapeJson(item.path)).Append("\",");
        builder.Append("\"agent\":\"").Append(EscapeJson(item.agent)).Append("\",");
        builder.Append("\"userAgent\":\"").Append(EscapeJson(item.userAgent)).Append("\",");
        builder.Append("\"status\":\"").Append(EscapeJson(item.status)).Append("\",");
        builder.Append("\"requestedAt\":\"").Append(EscapeJson(FormatQueueTime(item.requestedAt))).Append("\",");
        builder.Append("\"startedAt\":\"").Append(EscapeJson(FormatQueueTime(item.startedAt))).Append("\",");
        builder.Append("\"completedAt\":\"").Append(EscapeJson(FormatQueueTime(item.completedAt))).Append("\",");
        builder.Append("\"durationMilliseconds\":").Append(item.durationMilliseconds);
        builder.Append("}");
    }

    private static string FormatQueueTime(DateTime value)
    {
        return value == DateTime.MinValue ? "" : value.ToString("yyyy-MM-dd HH:mm:ss");
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

    private void WriteAudit(AdminUserRecord actor, string action, string detail)
    {
        string actorId = actor == null ? "" : actor.id;
        WriteJsonLog(this.auditLogPath, actorId, action, detail);
    }

    private void WriteAccess(string actorId, string action, string detail)
    {
        WriteJsonLog(this.accessLogPath, actorId, action, detail);
    }

    private void WriteClientDownload(HttpListenerRequest request, string action, string detail)
    {
        string ip = GetClientIp(request);
        string agent = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-Agent"], "");
        string computer = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-Computer"], "");
        string user = FirstNonEmpty(request.Headers["X-Safety-Wallpaper-User"], "");
        string userAgent = FirstNonEmpty(request.UserAgent, "");
        string line = "{\"time\":\"" + EscapeJson(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")) + "\"," +
                      "\"ip\":\"" + EscapeJson(ip) + "\"," +
                      "\"actor\":\"" + EscapeJson(ip) + "\"," +
                      "\"action\":\"" + EscapeJson(action) + "\"," +
                      "\"detail\":\"" + EscapeJson(detail) + "\"," +
                      "\"agent\":\"" + EscapeJson(agent) + "\"," +
                      "\"computer\":\"" + EscapeJson(computer) + "\"," +
                      "\"user\":\"" + EscapeJson(user) + "\"," +
                      "\"userAgent\":\"" + EscapeJson(userAgent) + "\"}";

        lock (this.logLock)
        {
            File.AppendAllText(this.clientDownloadLogPath, line + Environment.NewLine, new UTF8Encoding(false));
        }
    }

    private void WriteJsonLog(string path, string actorId, string action, string detail)
    {
        string line = "{\"time\":\"" + EscapeJson(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")) + "\"," +
                      "\"actor\":\"" + EscapeJson(actorId) + "\"," +
                      "\"action\":\"" + EscapeJson(action) + "\"," +
                      "\"detail\":\"" + EscapeJson(detail) + "\"}";

        lock (this.logLock)
        {
            File.AppendAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
        }
    }

    private static string GetClientIp(HttpListenerRequest request)
    {
        string forwarded = request.Headers["X-Forwarded-For"];

        if (!String.IsNullOrWhiteSpace(forwarded))
        {
            return forwarded.Split(',')[0].Trim();
        }

        return request.RemoteEndPoint == null ? "" : request.RemoteEndPoint.Address.ToString();
    }

    private static string GetDictionaryString(Dictionary<string, object> dictionary, string key)
    {
        if (dictionary == null)
        {
            return "";
        }

        object value;

        if (!dictionary.TryGetValue(key, out value) || value == null)
        {
            return "";
        }

        return Convert.ToString(value);
    }

    private static bool GetDictionaryBool(Dictionary<string, object> dictionary, string key)
    {
        if (dictionary == null)
        {
            return false;
        }

        object value;

        if (!dictionary.TryGetValue(key, out value) || value == null)
        {
            return false;
        }

        if (value is bool)
        {
            return (bool)value;
        }

        bool result;
        return Boolean.TryParse(Convert.ToString(value), out result) && result;
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

    private static string FirstNonEmpty(params string[] values)
    {
        if (values == null)
        {
            return "";
        }

        foreach (string value in values)
        {
            if (!String.IsNullOrWhiteSpace(value))
            {
                return value;
            }
        }

        return "";
    }

    private static string TrimOrEmpty(string value)
    {
        return String.IsNullOrWhiteSpace(value) ? "" : value.Trim();
    }

    private static bool IsUserActive(AdminUserRecord user)
    {
        if (user == null)
        {
            return false;
        }

        return user.active.HasValue ? user.active.Value : user.enabled;
    }

    private static void NormalizeAdminUser(AdminUserRecord user)
    {
        if (user == null)
        {
            return;
        }

        user.id = NormalizeAdminId(user.id);

        if (String.IsNullOrWhiteSpace(user.role))
        {
            user.role = "operator";
        }

        user.role = NormalizeRole(user.role);

        if (!user.active.HasValue)
        {
            user.active = user.enabled;
        }

        user.enabled = user.active.Value;
    }

    private static string NormalizeRole(string role)
    {
        if (String.Equals(role, "super", StringComparison.OrdinalIgnoreCase))
        {
            return "super";
        }

        return "operator";
    }

    private static bool IsSuperAdmin(AdminUserRecord user)
    {
        return user != null && String.Equals(NormalizeRole(user.role), "super", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsValidNewPassword(string password)
    {
        return !String.IsNullOrEmpty(password) && password.Length >= 8;
    }

    private static string MakeTemporaryPassword(int length)
    {
        const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#";

        if (length <= 0)
        {
            length = 12;
        }

        char[] chars = new char[length];
        byte[] bytes = new byte[length];

        using (RandomNumberGenerator rng = RandomNumberGenerator.Create())
        {
            rng.GetBytes(bytes);
        }

        for (int i = 0; i < length; i++)
        {
            chars[i] = alphabet[bytes[i] % alphabet.Length];
        }

        return new string(chars);
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
        string fileName = SanitizeFileName(GetUploadedFileName(request));
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

    private string DeleteUploadedImage(HttpListenerRequest request)
    {
        string imageUrl = GetDeleteImageUrl(request);
        string fileName = Path.GetFileName(imageUrl.Replace('\\', '/'));

        if (String.IsNullOrWhiteSpace(fileName))
        {
            throw new InvalidOperationException("\uc0ad\uc81c\ud560 \uc774\ubbf8\uc9c0 \uc815\ubcf4\uac00 \uc5c6\uc2b5\ub2c8\ub2e4.");
        }

        string targetPath = Path.GetFullPath(Path.Combine(this.imagesPath, fileName));
        string rootPath = Path.GetFullPath(this.imagesPath);

        if (!IsPathUnderRoot(targetPath, rootPath))
        {
            throw new InvalidOperationException("\uc774\ubbf8\uc9c0 \uacbd\ub85c\uac00 \uc62c\ubc14\ub974\uc9c0 \uc54a\uc2b5\ub2c8\ub2e4.");
        }

        if (!File.Exists(targetPath))
        {
            throw new InvalidOperationException("\uc774\ubbf8\uc9c0 \ud30c\uc77c\uc744 \ucc3e\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");
        }

        File.Delete(targetPath);

        string deletedUrl = "images/" + fileName;
        RemoveImageFromPolicy(deletedUrl);
        return deletedUrl;
    }

    private static string GetUploadedFileName(HttpListenerRequest request)
    {
        string decodedName = ReadUtf8Base64Header(request, "X-File-Name-Base64", "\uc5c5\ub85c\ub4dc \ud30c\uc77c\uba85\uc744 \uc77d\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");

        if (!String.IsNullOrWhiteSpace(decodedName))
        {
            return decodedName;
        }

        string rawName = request.QueryString["name"];

        if (String.IsNullOrWhiteSpace(rawName))
        {
            throw new InvalidOperationException("\uc5c5\ub85c\ub4dc \ud30c\uc77c\uba85\uc774 \uc5c6\uc2b5\ub2c8\ub2e4.");
        }

        return Uri.UnescapeDataString(rawName);
    }

    private static string GetDeleteImageUrl(HttpListenerRequest request)
    {
        string decodedUrl = ReadUtf8Base64Header(request, "X-Image-Url-Base64", "\uc0ad\uc81c\ud560 \uc774\ubbf8\uc9c0 \uc815\ubcf4\ub97c \uc77d\uc744 \uc218 \uc5c6\uc2b5\ub2c8\ub2e4.");

        if (!String.IsNullOrWhiteSpace(decodedUrl))
        {
            return decodedUrl;
        }

        string rawUrl = request.QueryString["url"];

        if (String.IsNullOrWhiteSpace(rawUrl))
        {
            throw new InvalidOperationException("\uc0ad\uc81c\ud560 \uc774\ubbf8\uc9c0 \uc815\ubcf4\uac00 \uc5c6\uc2b5\ub2c8\ub2e4.");
        }

        return Uri.UnescapeDataString(rawUrl);
    }

    private static string ReadUtf8Base64Header(HttpListenerRequest request, string headerName, string invalidMessage)
    {
        string encodedValue = request.Headers[headerName];

        if (String.IsNullOrWhiteSpace(encodedValue))
        {
            return "";
        }

        try
        {
            byte[] bytes = Convert.FromBase64String(encodedValue);
            return Encoding.UTF8.GetString(bytes);
        }
        catch
        {
            throw new InvalidOperationException(invalidMessage);
        }
    }

    private void RemoveImageFromPolicy(string deletedUrl)
    {
        if (!File.Exists(this.policyPath))
        {
            return;
        }

        string text = File.ReadAllText(this.policyPath, Encoding.UTF8);

        if (String.IsNullOrWhiteSpace(text))
        {
            return;
        }

        JavaScriptSerializer serializer = new JavaScriptSerializer();
        Dictionary<string, object> policy = serializer.Deserialize<Dictionary<string, object>>(text);

        if (policy == null)
        {
            return;
        }

        object slidesObj;

        if (!policy.TryGetValue("slides", out slidesObj) || !(slidesObj is ArrayList))
        {
            return;
        }

        string deletedFileName = Path.GetFileName(deletedUrl.Replace('\\', '/'));
        ArrayList keptSlides = new ArrayList();
        bool changed = false;

        foreach (object slideObj in (ArrayList)slidesObj)
        {
            Dictionary<string, object> slide = slideObj as Dictionary<string, object>;

            if (slide != null &&
                (IsSameImageReference(GetDictionaryString(slide, "url"), deletedUrl, deletedFileName) ||
                 IsSameImageReference(GetDictionaryString(slide, "file"), deletedUrl, deletedFileName)))
            {
                changed = true;
                continue;
            }

            keptSlides.Add(slideObj);
        }

        if (!changed)
        {
            return;
        }

        policy["slides"] = keptSlides;
        policy["policyVersion"] = DateTime.Now.ToString("yyyyMMddHHmmss");
        File.WriteAllText(this.policyPath, serializer.Serialize(policy), new UTF8Encoding(false));
    }

    private static bool IsSameImageReference(string value, string deletedUrl, string deletedFileName)
    {
        if (String.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        string normalized = value.Trim().Replace('\\', '/');

        if (normalized.StartsWith("/safety-wallpaper/", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized.Substring("/safety-wallpaper/".Length);
        }
        else if (normalized.StartsWith("safety-wallpaper/", StringComparison.OrdinalIgnoreCase))
        {
            normalized = normalized.Substring("safety-wallpaper/".Length);
        }

        if (String.Equals(normalized, deletedUrl, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return String.Equals(Path.GetFileName(normalized), deletedFileName, StringComparison.OrdinalIgnoreCase);
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
