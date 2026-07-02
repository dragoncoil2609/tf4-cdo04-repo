import { useEffect, useState } from "react";
import { api } from "./api/client";
import type { LoginResponse, SessionState } from "./api/types";
import { Layout, type Page } from "./components/Layout";
import { InfraScreen } from "./screens/InfraScreen";
import { LoginScreen } from "./screens/LoginScreen";
import { MetricsScreen } from "./screens/MetricsScreen";
import { OverviewScreen } from "./screens/OverviewScreen";
import { PoliciesScreen } from "./screens/PoliciesScreen";
import { ProbesScreen } from "./screens/ProbesScreen";

export function App() {
  const [session, setSession] = useState<SessionState | null>(null);
  const [page, setPage] = useState<Page>("overview");
  const [tenantId, setTenantId] = useState("");
  const [serviceId, setServiceId] = useState("");
  const [booting, setBooting] = useState(true);

  useEffect(() => {
    api.session().then(setSession).catch(() => undefined).finally(() => setBooting(false));
  }, []);

  const onLogin = (response: LoginResponse) => {
    setSession({
      profile: response.profile ?? null,
      account_id: response.account_id ?? null,
      region: response.region ?? "us-east-1",
      logged_in_at: new Date().toISOString(),
      is_logged_in: true,
    });
  };

  const onLogout = async () => {
    await api.logout().catch(() => undefined);
    setSession(null);
  };

  if (booting) return <div className="shell" style={{ padding: "2rem" }}>Loading session...</div>;
  if (!session?.is_logged_in) return <LoginScreen onLogin={onLogin} />;

  return (
    <Layout page={page} session={session} onNavigate={setPage} onLogout={onLogout}>
      {page === "overview" ? (
        <OverviewScreen
          tenantId={tenantId}
          onTenantChange={setTenantId}
          onOpenMetrics={(nextService) => {
            setServiceId(nextService);
            setPage("metrics");
          }}
        />
      ) : null}
      {page === "metrics" ? <MetricsScreen tenantId={tenantId} serviceId={serviceId} onServiceChange={setServiceId} /> : null}
      {page === "policies" ? <PoliciesScreen tenantId={tenantId} /> : null}
      {page === "probes" ? <ProbesScreen /> : null}
      {page === "infra" ? <InfraScreen /> : null}
    </Layout>
  );
}
