if ($null -eq ('MediaNormalizerZipPrivacyScanner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;

public static class MediaNormalizerZipPrivacyScanner
{
    public static bool ContainsAny(Stream stream, byte[][] patterns)
    {
        if (patterns == null || patterns.Length == 0) return false;
        var maximumPatternLength = 0;
        foreach (var pattern in patterns)
        {
            if (pattern != null && pattern.Length > maximumPatternLength)
                maximumPatternLength = pattern.Length;
        }
        if (maximumPatternLength == 0) return false;

        const int chunkLength = 65536;
        var buffer = new byte[chunkLength + maximumPatternLength - 1];
        var carry = 0;
        while (true)
        {
            var read = stream.Read(buffer, carry, chunkLength);
            if (read == 0) return false;
            var available = carry + read;
            var haystack = new ReadOnlySpan<byte>(buffer, 0, available);
            foreach (var pattern in patterns)
            {
                if (pattern != null && pattern.Length > 0 && haystack.IndexOf(pattern) >= 0)
                    return true;
            }

            carry = Math.Min(maximumPatternLength - 1, available);
            if (carry > 0)
                Buffer.BlockCopy(buffer, available - carry, buffer, 0, carry);
        }
    }
}
'@
}
