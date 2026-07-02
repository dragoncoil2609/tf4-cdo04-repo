import { useEffect, useState } from "react";
import { api } from "../api/client";
import type { LoginResponse, Profile } from "../api/types";

interface LoginScreenProps {
  onLogin: (response: LoginResponse) => void;
}

export function LoginScreen({ onLogin }: LoginScreenProps) {
  const [profiles, setProfiles] = useState<Profile[]>([]);
  const [profile, setProfile] = useState("");
  const [region, setRegion] = useState("us-east-1");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    api
      .profiles()
      .then((response) => {
        setProfiles(response.profiles);
        setProfile(response.profiles[0]?.name ?? "");
      })
      .catch((err: Error) => setError(err.message))
      .finally(() => setLoading(false));
  }, []);

  const submit = async () => {
    setBusy(true);
    setError("");
    try {
      const response = await api.login({ profile: profile || undefined, region });
      if (response.status !== "ok") throw new Error(response.detail ?? response.error ?? "Login failed");
      onLogin(response);
    } catch (err) {
      setError(err instanceof Error ? err.message : "SSO login failed. Run `aws sso login`.");
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="shell" style={{ display: "grid", placeItems: "center", padding: "1rem" }}>
      <section className="panel" style={{ width: "min(520px, 100%)" }}>
        <h1>CDO SRE Dashboard</h1>
        <p className="muted">Local-only. AWS credentials stay in backend process.</p>
        {loading ? <p>Loading profiles...</p> : null}
        {!loading && !profiles.length ? (
          <div className="banner error">No AWS profiles found. Run <code>aws configure</code>.</div>
        ) : null}
        {error ? <div className="banner error">{error}</div> : null}
        <div className="stack" style={{ marginTop: "1rem" }}>
          <label className="stack">
            <span>AWS profile</span>
            <select value={profile} onChange={(event) => setProfile(event.target.value)} disabled={!profiles.length}>
              {profiles.map((item) => (
                <option key={item.name} value={item.name}>
                  {item.name} ({item.source})
                </option>
              ))}
            </select>
          </label>
          <label className="stack">
            <span>Region</span>
            <input value={region} onChange={(event) => setRegion(event.target.value)} />
          </label>
          <button className="primary" type="button" onClick={submit} disabled={busy || loading || !profiles.length}>
            {busy ? "Logging in..." : "Login"}
          </button>
        </div>
      </section>
    </div>
  );
}
