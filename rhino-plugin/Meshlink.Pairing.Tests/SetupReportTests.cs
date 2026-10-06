using Xunit;

namespace Meshlink.Pairing.Tests
{
    public class SetupReportTests
    {
        // Shaped like prepare-windows.ps1 -ResultFile output.
        static readonly string[] File =
        {
            "RESULT ok",
            "USER rhino-agent",
            "LINE [ OK ] sshd is running and starts with Windows",
            "LINE        -> not a hint of anything",
            "LINE [WARN] UAC is off: code run through Rhino has full administrator rights, whatever account SSH uses",
            "LINE        -> see docs/remote-setup.md, Security",
            "LINE [DONE] key added to C:\\Users\\rhino-agent\\.ssh\\authorized_keys",
            "LINE [SKIP] installing uv and rhinomcp for rhino-agent: it has to run as that account",
            "LINE        -> runas /user:rhino-agent powershell    then, in the window that opens:",
            "LINE [INFO] nothing listens on port 1999 now; run mcpstart in Rhino before using it",
        };

        [Fact]
        public void ReadsTheResult()
        {
            var r = SetupReport.Parse(File);
            Assert.True(r.Ok);
            Assert.Equal("rhino-agent", r.User);
            Assert.Equal(8, r.Lines.Count);
            Assert.False(SetupReport.Parse(new[] { "RESULT fail" }).Ok);
            Assert.False(SetupReport.Parse(new string[0]).Ok);
        }

        [Fact]
        public void TellsTheMacWarningsSkipsAndTheirHints()
        {
            Assert.Equal(new[]
            {
                "[WARN] UAC is off: code run through Rhino has full administrator rights, whatever account SSH uses",
                "-> see docs/remote-setup.md, Security",
                "[SKIP] installing uv and rhinomcp for rhino-agent: it has to run as that account",
                "-> runas /user:rhino-agent powershell    then, in the window that opens:",
            }, SetupReport.Parse(File).Notable());
        }
    }
}
