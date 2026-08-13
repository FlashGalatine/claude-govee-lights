using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace GoveeLights
{
    /// <summary>
    /// Replaces the top-level "States" block in a config file, leaving every other byte
    /// alone.
    ///
    /// A full round-trip through JavaScriptSerializer would be far simpler, and would
    /// silently delete every _comment key in the file - including the ones the shipped
    /// example config and the README rely on to explain themselves. So this edits the
    /// text instead.
    ///
    /// Depth matters: Devices[].States exists, and _examples_states sits alongside, so
    /// only a "States" key at depth 1 is the right one.
    /// </summary>
    public static class ConfigWriter
    {
        public static bool TrySpliceStates(string json, string statesBlock,
                                           out string result, out string error)
        {
            result = null; error = null;
            if (json == null) { error = "no config text"; return false; }

            int keyStart, valueStart, valueEnd, indent;
            string nonObjectValue;
            if (FindTopLevelStates(json, out keyStart, out valueStart, out valueEnd, out indent, out nonObjectValue))
            {
                result = json.Substring(0, valueStart) + statesBlock + json.Substring(valueEnd);
                return true;
            }

            if (nonObjectValue != null)
            {
                // The key exists but is not something we can safely replace - null, an
                // array, a string, a number, a boolean, or an unterminated object. That is
                // not "no key", and treating it as one would append a second "States"
                // member; JavaScriptSerializer would keep one and silently discard the
                // other. The class's whole promise is "leave every other byte alone, or
                // refuse" - never guess.
                error = "top-level \"States\" is " + nonObjectValue + ", not an object; refusing to guess";
                return false;
            }

            // No States key at all: insert one before the final closing brace.
            string head; int close;
            if (!TryFindInsertPrefix(json, out head, out close))
            { error = "config has no closing brace"; return false; }

            var sep = head.EndsWith("{") ? "" : ",";
            result = head + sep + "\n  \"States\": " + statesBlock + "\n" + json.Substring(close);
            return true;
        }

        /// <summary>Locate the depth-1 "States" member. valueStart/valueEnd bracket its
        /// object value; indent is the column its key started at. Returns false both when
        /// there is no such key at all (nonObjectValue stays null) and when there is one
        /// but its value is not an object we can splice into (nonObjectValue names what it
        /// found) - callers must tell those two apart.</summary>
        static bool FindTopLevelStates(string json, out int keyStart, out int valueStart,
                                       out int valueEnd, out int indent, out string nonObjectValue)
        {
            keyStart = valueStart = valueEnd = -1; indent = 2; nonObjectValue = null;

            int depth = 0, i = 0, lineStart = 0;
            bool inStr = false, esc = false;

            while (i < json.Length)
            {
                var c = json[i];

                if (esc) { esc = false; i++; continue; }
                if (c == '\\' && inStr) { esc = true; i++; continue; }
                if (c == '"' && !inStr)
                {
                    // A key only counts at depth 1 and only if it is followed by a colon.
                    if (depth == 1 && MatchesKey(json, i, "States"))
                    {
                        var afterKey = i + 8; // "States" plus both quotes
                        var j = SkipWhitespace(json, afterKey);
                        if (j < json.Length && json[j] == ':')
                        {
                            j = SkipWhitespace(json, j + 1);
                            keyStart = i;
                            if (j < json.Length && json[j] == '{')
                            {
                                valueStart = j;
                                valueEnd = MatchBrace(json, j);
                                indent = i - lineStart;
                                if (valueEnd > 0) return true;

                                nonObjectValue = "an unterminated object";
                                return false;
                            }

                            // The key exists but is not an object.
                            nonObjectValue = DescribeJsonValue(json, j);
                            return false;
                        }
                    }
                    inStr = true; i++; continue;
                }
                if (c == '"') { inStr = false; i++; continue; }
                if (inStr) { i++; continue; }

                if (c == '\n') lineStart = i + 1;
                else if (c == '{' || c == '[') depth++;
                else if (c == '}' || c == ']') depth--;
                i++;
            }
            return false;
        }

        /// <summary>Name what sits at position i in the JSON text, for the refusal message
        /// when a top-level "States" is not an object.</summary>
        static string DescribeJsonValue(string json, int i)
        {
            if (i >= json.Length) return "missing a value";
            var c = json[i];
            if (c == 'n') return "null";
            if (c == '[') return "an array";
            if (c == '"') return "a string";
            if (c == 't' || c == 'f') return "a boolean";
            if (c == '-' || (c >= '0' && c <= '9')) return "a number";
            return "not an object";
        }

        static bool MatchesKey(string json, int quoteIndex, string key)
        {
            if (quoteIndex + key.Length + 1 >= json.Length) return false;
            if (json[quoteIndex + key.Length + 1] != '"') return false;
            return string.CompareOrdinal(json, quoteIndex + 1, key, 0, key.Length) == 0;
        }

        static int SkipWhitespace(string json, int i)
        {
            while (i < json.Length && char.IsWhiteSpace(json[i])) i++;
            return i;
        }

        /// <summary>Index just past the '}' matching the '{' at open, or -1.</summary>
        static int MatchBrace(string json, int open)
        {
            int depth = 0;
            bool inStr = false, esc = false;
            for (int i = open; i < json.Length; i++)
            {
                var c = json[i];
                if (esc) { esc = false; continue; }
                if (c == '\\' && inStr) { esc = true; continue; }
                if (c == '"') { inStr = !inStr; continue; }
                if (inStr) continue;
                if (c == '{') depth++;
                else if (c == '}') { depth--; if (depth == 0) return i + 1; }
            }
            return -1;
        }

        /// <summary>Where the "insert a new States key" path draws the line: everything up
        /// to (and including trailing-whitespace trimming of) the final '}' is kept as
        /// `head`; everything from `close` onward is kept verbatim. Shared by
        /// TrySpliceStates (which builds the result this way) and TrySave (which verifies
        /// the result was actually built this way) so the two cannot drift on what
        /// "unchanged" means.</summary>
        static bool TryFindInsertPrefix(string json, out string head, out int close)
        {
            close = json.LastIndexOf('}');
            head = close >= 0 ? json.Substring(0, close).TrimEnd() : null;
            return close >= 0;
        }

        /// <summary>Render a States block at the file's own 2-space convention.</summary>
        public static string RenderStates(Dictionary<string, StateStyle> states, int indentSpaces)
        {
            if (states == null) states = new Dictionary<string, StateStyle>();
            var pad = new string(' ', indentSpaces);
            var inner = pad + "  ";

            var ser = new JavaScriptSerializer();
            var sb = new StringBuilder();
            sb.Append("{");

            var first = true;
            foreach (var kv in states)
            {
                string body;
                if (!Writable(kv.Value, out body)) continue;
                if (!first) sb.Append(",");
                first = false;
                sb.Append("\n").Append(inner).Append(ser.Serialize(kv.Key)).Append(": ").Append(body);
            }

            if (!first) sb.Append("\n").Append(pad);
            sb.Append("}");
            return sb.ToString();
        }

        /// <summary>A style is worth writing when it is non-null and says at least one
        /// thing.</summary>
        static bool Writable(StateStyle s, out string body)
        {
            body = null;
            if (s == null) return false;
            var ser = new JavaScriptSerializer();
            body = StripNullMembers(ser.Serialize(s));
            return body != "{}";              // an all-null style says nothing
        }

        /// <summary>Same intent as DaemonConfig's null stripper, scoped to one object and
        /// kept here so the writer does not depend on that private helper.</summary>
        static string StripNullMembers(string json)
        {
            var ser = new JavaScriptSerializer();
            var map = ser.Deserialize<Dictionary<string, object>>(json);
            var keep = new Dictionary<string, object>();
            foreach (var kv in map) if (kv.Value != null) keep[kv.Key] = kv.Value;
            return ser.Serialize(keep);
        }

        /// <summary>Read a file's text while remembering whether it had a byte-order mark,
        /// so a save can write the same encoding back. File.ReadAllText silently absorbs a
        /// BOM; writing plain UTF-8 (or UTF-8-with-BOM) back over a file that was the other
        /// way would change bytes outside the States block - exactly what this class
        /// promises not to do.</summary>
        static string ReadAllTextPreservingEncoding(string path, out Encoding encoding)
        {
            using (var reader = new StreamReader(path, new UTF8Encoding(false), true))
            {
                var text = reader.ReadToEnd();
                encoding = reader.CurrentEncoding;
                return text;
            }
        }

        /// <summary>Splice, validate by round-trip, then replace atomically. Returns false
        /// and writes nothing if anything looks wrong - a splicer that silently corrupts a
        /// config is worse than one that refuses.</summary>
        public static bool TrySave(string path, Dictionary<string, StateStyle> states, out string error)
        {
            error = null;
            try
            {
                Encoding encoding;
                var original = ReadAllTextPreservingEncoding(path, out encoding);

                // Reuse the existing key's column so a save does not reformat the file.
                // FindTopLevelStates leaves indent at its default of 2 when there is no
                // States key yet, which is the right column for an inserted one.
                int ks, vs, ve, indent;
                string nonObjectValue;
                var hadKey = FindTopLevelStates(original, out ks, out vs, out ve, out indent, out nonObjectValue);

                var block = RenderStates(states, indent);

                string spliced;
                if (!TrySpliceStates(original, block, out spliced, out error))
                    return false;

                // 1. The result must parse.
                var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
                DaemonConfig check;
                try { check = ser.Deserialize<DaemonConfig>(spliced); }
                catch (Exception ex) { error = "spliced config does not parse: " + ex.Message; return false; }
                if (check == null) { error = "spliced config deserialized to null"; return false; }

                // 2. What actually landed must re-render to exactly the block we meant to
                // write - not merely the same entry count. A splice that hit the wrong
                // location (or dropped/altered a value) leaves check.States holding
                // something else, and re-rendering it would not reproduce `block` byte for
                // byte. Reusing RenderStates on both sides also means the Writable filter
                // that decides what gets written cannot drift from what this check expects
                // - there is only one copy of that decision.
                var wroteBlock = RenderStates(check.States ?? new Dictionary<string, StateStyle>(), indent);
                if (wroteBlock != block)
                {
                    error = "round-trip mismatch: the written States block does not match what was spliced in";
                    return false;
                }

                // 3. Every byte outside the replaced span must be untouched - preserving
                // them is this class's entire reason to exist instead of a re-serialise.
                if (hadKey)
                {
                    if (spliced.Substring(0, vs) != original.Substring(0, vs) ||
                        spliced.Substring(vs + block.Length) != original.Substring(ve))
                    {
                        error = "round-trip mismatch: bytes outside the States block changed";
                        return false;
                    }
                }
                else
                {
                    string head; int close;
                    if (!TryFindInsertPrefix(original, out head, out close) ||
                        !spliced.StartsWith(head, StringComparison.Ordinal) ||
                        !spliced.EndsWith(original.Substring(close), StringComparison.Ordinal))
                    {
                        error = "round-trip mismatch: bytes around the inserted States block changed";
                        return false;
                    }
                }

                var tmp = path + ".tmp";
                try
                {
                    File.WriteAllText(tmp, spliced, encoding);
                    if (File.Exists(path)) File.Replace(tmp, path, null);
                    else File.Move(tmp, path);
                    return true;
                }
                catch (Exception ex)
                {
                    // Don't leave a stray .tmp beside the user's config if the final
                    // replace/move step itself throws - a locked file, an antivirus scan
                    // mid-flight.
                    try { if (File.Exists(tmp)) File.Delete(tmp); } catch { /* best effort */ }
                    error = ex.Message;
                    return false;
                }
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
