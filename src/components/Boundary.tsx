import { Component, type ErrorInfo, type ReactNode } from 'react'

/**
 * WHAT THE WHITE SCREEN WAS.
 *
 * React unmounts the entire tree when a render or an effect throws, and an app
 * with nothing to catch that is left showing the browser's blank page. It is
 * the worst failure this app has, for three reasons: there is no way back
 * except a reload, the reload loses nothing on the server but feels like it
 * might, and -- the part that cost a day -- the player cannot tell anybody
 * WHAT broke. "Everything turns white" is the same sentence for every possible
 * bug, and on a phone there is no console to look in.
 *
 * So: catch it, say what it was, and offer the one button that helps. The
 * match itself is on the server and the clock is on the server, so a reload
 * genuinely does drop you back into the same turn -- which is worth saying out
 * loud, because the instinct is that reloading forfeits.
 *
 * The error text is shown rather than merely logged, and it is selectable, and
 * there is a button that copies it. A bug report that includes the stack is
 * worth twenty that say the screen went white.
 *
 * NOT a replacement for fixing whatever threw. A boundary that quietly hides
 * crashes is worse than the crash, which is why this one is loud and why it
 * logs to the console as well.
 */

interface Props {
  children: ReactNode
  /** Shown above the error, so the panel can say which part of the app fell
   *  over -- the match boundary and the outer one are different news. */
  where?: string
  /** Offered when there is somewhere to go that is not a reload. */
  onOut?: () => void
  outLabel?: string
}
interface State { err: Error | null; stack: string }

export class Boundary extends Component<Props, State> {
  state: State = { err: null, stack: '' }

  static getDerivedStateFromError(err: Error): Partial<State> {
    return { err }
  }

  componentDidCatch(err: Error, info: ErrorInfo) {
    // Still shouted at the console. The panel is for the player; this is for
    // whoever has devtools open.
    console.error('[crown-nemesis] crashed:', err, info.componentStack)
    this.setState({ stack: (info.componentStack ?? '').trim() })
  }

  render() {
    const { err, stack } = this.state
    if (!err) return this.props.children

    // Deliberately in English and not through the translator. The translator
    // is a hook in a React tree that has just proved it can throw, and a
    // boundary that needs the app to work is not a boundary.
    const text = `${err.name}: ${err.message}\n${(err.stack ?? '').split('\n').slice(1, 6).join('\n')}\n---\n${stack.split('\n').slice(0, 8).join('\n')}`

    return (
      <div className="crashed" role="alert">
        <div className="crashed-box">
          <h1>Something broke{this.props.where ? ` in the ${this.props.where}` : ''}.</h1>
          <p>
            Nothing is lost. The board and the clock live on the server, so
            reloading puts you back in the same turn.
          </p>
          <pre className="crashed-what">{text}</pre>
          <div className="crashed-row">
            <button className="btn" onClick={() => window.location.reload()}>Reload</button>
            <button
              className="btn ghost"
              onClick={() => { void navigator.clipboard?.writeText(text) }}
            >
              Copy the error
            </button>
            {this.props.onOut && (
              <button className="btn ghost" onClick={this.props.onOut}>
                {this.props.outLabel ?? 'Back to the menu'}
              </button>
            )}
          </div>
        </div>
      </div>
    )
  }
}
