using System;
using System.IO;

namespace Meshlink.Pairing.Tests
{
    static class Repo
    {
        /// <summary>The repository root, found upwards from the test binaries.</summary>
        public static string Root
        {
            get
            {
                for (var d = new DirectoryInfo(AppContext.BaseDirectory); d != null; d = d.Parent)
                    if (File.Exists(Path.Combine(d.FullName, "tests", "pairing-vectors.txt"))) return d.FullName;
                throw new InvalidOperationException("repository root not found above " + AppContext.BaseDirectory);
            }
        }

        public static string PathOf(params string[] parts)
        {
            return Path.Combine(Root, Path.Combine(parts));
        }
    }
}
