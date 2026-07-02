import { useEffect, useState } from "react";
import { ApiError, api } from "../api/client";
import type { Policy } from "../api/types";

interface EditState {
  policy: Policy;
  nextThreshold: number;
}

interface PoliciesScreenProps {
  tenantId: string;
}

export function PoliciesScreen({ tenantId }: PoliciesScreenProps) {
  const [policies, setPolicies] = useState<Policy[]>([]);
  const [edit, setEdit] = useState<EditState | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const load = () => {
    if (!tenantId) return;
    api.policies(tenantId).then((response) => setPolicies(response.policies)).catch((err: Error) => setError(err.message));
  };

  useEffect(load, [tenantId]);

  const confirm = async () => {
    if (!edit) return;
    setBusy(true);
    setError("");
    try {
      await api.updatePolicy(edit.policy.tenant_id, edit.policy.service_name, {
        static_threshold: edit.nextThreshold,
        enabled: edit.policy.enabled,
        expected_old_value: edit.policy.static_threshold,
      });
      setEdit(null);
      load();
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        setError("Policy was modified by another session. Reload and try again.");
      } else {
        setError(err instanceof Error ? err.message : "Update failed");
      }
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="stack">
      <div>
        <h1>Policies</h1>
        <p className="muted">Fallback thresholds. Updates use expected_old_value.</p>
      </div>
      {error ? <div className="banner error">{error}</div> : null}
      {!policies.length ? <p>No policies configured for this tenant.</p> : null}
      <section className="panel table-wrap">
        <table>
          <thead><tr><th>Tenant</th><th>Service</th><th>Threshold</th><th>Enabled</th><th>Action</th></tr></thead>
          <tbody>
            {policies.map((policy) => (
              <tr key={`${policy.tenant_id}-${policy.service_name}`}>
                <td>{policy.tenant_id}</td>
                <td>{policy.service_name}</td>
                <td>{policy.static_threshold}</td>
                <td>{String(policy.enabled)}</td>
                <td>
                  <button
                    className="secondary"
                    type="button"
                    onClick={() => setEdit({ policy, nextThreshold: policy.static_threshold })}
                  >
                    Edit
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>
      {edit ? (
        <div className="modal-backdrop" role="presentation">
          <section className="modal" role="dialog" aria-modal="true" aria-labelledby="policy-edit-title">
            <h2 id="policy-edit-title">Update Policy Threshold</h2>
            <label className="stack">
              <span>New threshold</span>
              <input
                min={0}
                max={100}
                type="number"
                value={edit.nextThreshold}
                onChange={(event) => setEdit({ ...edit, nextThreshold: Number(event.target.value) })}
              />
            </label>
            <p className="muted">Change {edit.policy.service_name} threshold from {edit.policy.static_threshold}% to {edit.nextThreshold}%?</p>
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button className="secondary" type="button" onClick={() => setEdit(null)} disabled={busy}>Cancel</button>
              <button className="primary" type="button" onClick={confirm} disabled={busy}>Confirm Update</button>
            </div>
          </section>
        </div>
      ) : null}
    </section>
  );
}
