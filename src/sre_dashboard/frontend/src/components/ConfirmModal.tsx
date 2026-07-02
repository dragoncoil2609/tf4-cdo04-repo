interface ConfirmModalProps {
  title: string;
  body: string;
  busy?: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}

export function ConfirmModal({ title, body, busy, onCancel, onConfirm }: ConfirmModalProps) {
  return (
    <div className="modal-backdrop" role="presentation">
      <section className="modal" role="dialog" aria-modal="true" aria-labelledby="confirm-title">
        <h2 id="confirm-title">{title}</h2>
        <p className="muted">{body}</p>
        <div className="row" style={{ justifyContent: "flex-end", marginTop: "1rem" }}>
          <button className="secondary" type="button" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
          <button className="primary" type="button" onClick={onConfirm} disabled={busy}>
            Confirm Update
          </button>
        </div>
      </section>
    </div>
  );
}
