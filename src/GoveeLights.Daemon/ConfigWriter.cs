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
            if (FindTopLevelStates(json, out keyStart, out valueStart, out valueEnd, out indent))
            {
                result = json.Substring(0, valueStart) + statesBlock + json.Substring(valueEnd);
                return true;
            }

            // No States key: insert one before the final closing brace.
            var close = json.LastIndexOf('}');
            if (close < 0) { error = "config has no closing brace"; return false; }

            var head = json.Substring(0, close).TrimEnd();
            var sep = head.EndsWith("{") ? "" : ",";
            result = head + sep + "\n  \"States\": " + statesBlock + "\n" + json.Substring(close);
            return true;
        }

        /// <summary>Locate the depth-1 "States" member. valueStart/valueEnd bracket its
        /// object value; indent is the column its key started at.</summary>
        static bool FindTopLevelStates(string json, out int keyStart, out int valueStart,
                                       out int valueEnd, out int indent)
        {
            keyStart = valueStart = valueEnd = -1; indent = 2;

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
                            if (j < json.Length && json[j] == '{')
                            {
                                keyStart = i;
                                valueStart = j;
                                valueEnd = MatchBrace(json, j);
                                indent = i - lineStart;
                                return valueEnd > 0;
                            }
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
        /// thing. Shared by RenderStates (what actually gets written) and TrySave's
        /// round-trip count (what we expect to find after writing) so the two can never
        /// drift apart - see the bug note below.</summary>
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

        /// <summary>Splice, validate by round-trip, then replace atomically. Returns false
        /// and writes nothing if anything looks wrong - a splicer that silently corrupts a
        /// config is worse than one that refuses.</summary>
        public static bool TrySave(string path, Dictionary<string, StateStyle> states, out string error)
        {
            error = null;
            try
            {
                var original = File.ReadAllText(path);

                // Reuse the existing key's column so a save does not reformat the file.
                // FindTopLevelStates leaves indent at its default of 2 when there is no
                // States key yet, which is the right column for an inserted one.
                int ks, vs, ve, indent;
                FindTopLevelStates(original, out ks, out vs, out ve, out indent);

                string spliced;
                if (!TrySpliceStates(original, RenderStates(states, indent), out spliced, out error))
                    return false;

                // Round-trip: the result must parse, and must carry exactly the states we
                // meant to write.
                var ser = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
                DaemonConfig check;
                try { check = ser.Deserialize<DaemonConfig>(spliced); }
                catch (Exception ex) { error = "spliced config does not parse: " + ex.Message; return false; }
                if (check == null) { error = "spliced config deserialized to null"; return false; }

                var wrote = check.States ?? new Dictionary<string, StateStyle>();

                // Counted with the same Writable predicate RenderStates filters by - not
                // just "non-null" - or an all-null style (serialises to "{}" and is
                // skipped by RenderStates) would make wanted overcount and every save with
                // one in it fail the round-trip check below.
                var wanted = 0;
                foreach (var kv in states) { string b; if (Writable(kv.Value, out b)) wanted++; }
                if (wrote.Count != wanted)
                {
                    error = "round-trip mismatch: wrote " + wrote.Count + ", expected " + wanted;
                    return false;
                }

                var tmp = path + ".tmp";
                File.WriteAllText(tmp, spliced);
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else File.Move(tmp, path);
                return true;
            }
            catch (Exception ex) { error = ex.Message; return false; }
        }
    }
}
