import type { ReactNode } from "react";
import type { SessionState } from "../api/types";

type Page = "overview" | "metrics" | "policies" | "probes" | "infra";

interface LayoutProps {
  children: ReactNode;
  page: Page;
  session: SessionState | null;
  onNavigate: (page: Page) => void;
  onLogout: () => void;
}

const pages: Page[] = ["overview", "metrics", "policies", "probes", "infra"];

export function Layout({ children, page, session, onNavigate, onLogout }: LayoutProps) {
  return (
    <div className="shell">
      <header className="topbar">
        <div className="logo">
          <strong>CDO SRE Dashboard</strong>
          <span className="muted">local-only control plane</span>
        </div>
        <div className="row">
          <span className="muted">
            Profile: {session?.profile ?? "not logged in"} · {session?.account_id ?? "no account"}
          </span>
          <button className="secondary" type="button" onClick={onLogout}>
            Logout
          </button>
        </div>
      </header>
      <nav className="navbar" aria-label="Main navigation">
        {pages.map((item) => (
          <button
            className={item === page ? "active" : ""}
            key={item}
            type="button"
            onClick={() => onNavigate(item)}
          >
            {item[0].toUpperCase() + item.slice(1)}
          </button>
        ))}
      </nav>
      <main>{children}</main>
    </div>
  );
}

export type { Page };
