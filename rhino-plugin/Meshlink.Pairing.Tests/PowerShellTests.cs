using System.IO;
using System.Linq;
using System.Management.Automation.Language;
using Xunit;

namespace Meshlink.Pairing.Tests
{
    /// <summary>
    /// scripts/prepare-windows.ps1 has no automated run (it changes Windows);
    /// this at least catches syntax errors and PowerShell 7-only syntax before
    /// a Windows round trip. It runs on Windows PowerShell 5.1 (AGENTS.md).
    /// </summary>
    public class PowerShellTests
    {
        static readonly string Script = Repo.PathOf("scripts", "prepare-windows.ps1");

        [Fact]
        public void Parses()
        {
            Token[] tokens;
            ParseError[] errors;
            Parser.ParseFile(Script, out tokens, out errors);
            Assert.Empty(errors.Select(e => e.Extent.StartLineNumber + ": " + e.Message));
        }

        [Fact]
        public void UsesNoPowerShell7Syntax()
        {
            Token[] tokens;
            ParseError[] errors;
            Parser.ParseFile(Script, out tokens, out errors);
            var seven = new[]
            {
                TokenKind.AndAnd, TokenKind.OrOr, TokenKind.QuestionMark, TokenKind.QuestionQuestion,
                TokenKind.QuestionQuestionEquals, TokenKind.QuestionDot, TokenKind.QuestionLBracket,
            };
            Assert.Empty(tokens.Where(t => seven.Contains(t.Kind))
                               .Select(t => t.Extent.StartLineNumber + ": " + t.Text));
        }

        [Fact]
        public void IsAsciiOnly()
        {
            var bytes = File.ReadAllBytes(Script);
            Assert.DoesNotContain(bytes, b => b > 0x7f);
        }
    }
}
