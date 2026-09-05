import { useId } from 'react'

/**
 * The mark. A rotated square with a chevron cut out of it -- every edge is at
 * 45 degrees, which is why it sits comfortably next to a board made of squares.
 *
 * Drawn, not linked: it is a dozen coordinates, so inlining it costs less than
 * the request would and means it can never arrive after the page it belongs to.
 * The gradient id is per-instance, because two copies on one page sharing an id
 * would leave the second one painting from the first one's definition.
 */
export function Logo({ className = 'logo', title }: { className?: string; title?: string }) {
  const id = useId()
  return (
    <svg
      className={className}
      viewBox="0 0 100 100"
      role={title ? 'img' : 'presentation'}
      aria-label={title}
      aria-hidden={title ? undefined : true}
    >
      {title && <title>{title}</title>}
      <linearGradient id={id} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stopColor="#3E6AF5" />
        <stop offset=".15" stopColor="#4466F3" />
        <stop offset=".29" stopColor="#5E46E0" />
        <stop offset=".43" stopColor="#A43597" />
        <stop offset=".57" stopColor="#D7345F" />
        <stop offset=".71" stopColor="#EB434A" />
        <stop offset=".85" stopColor="#F4583D" />
        <stop offset="1" stopColor="#F35539" />
      </linearGradient>
      <path
        fill={`url(#${id})`}
        d="M26.5 73.5 50 50l11.75 11.75L73.5 50 50 26.5 14.75 61.75 3 50 50 3l47 47-47 47Z"
      />
    </svg>
  )
}
