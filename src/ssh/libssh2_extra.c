/* Small additions to the vendored libssh2 (kept out of vendor/ so the
 * upstream sources stay untouched). Built only with addLibssh2.
 *
 * libssh2 keeps every SSH_MSG_REQUEST_SUCCESS/FAILURE it receives in the
 * session's packet list until a global request (tcpip-forward) asks for
 * one. The replies to keepalive@openssh.com (want_reply=1) therefore pile
 * up, and the next libssh2_channel_forward_listen_ex() takes a stale
 * keepalive FAILURE as its own answer: it reports "refused" although the
 * server bound the port, and then rejects the server's forwarded channels
 * ("Forward not requested"). These helpers let the client account for
 * keepalive replies and drop them before it sends a global request.
 */
#include "libssh2_priv.h"
#include "packet.h"

/* Sends a keepalive if one is due. Returns 1 when a request expecting a
 * reply went out, 0 when nothing was sent, <0 on error. */
int dt_libssh2_keepalive_send(LIBSSH2_SESSION *session, int *seconds_to_next)
{
    time_t before = session->keepalive_last_sent;
    int rc = libssh2_keepalive_send(session, seconds_to_next);
    if(rc < 0)
        return rc;
    return (session->keepalive_last_sent != before &&
            session->keepalive_want_reply) ? 1 : 0;
}

/* Removes queued global-request replies; returns how many were dropped. */
int dt_libssh2_drop_global_replies(LIBSSH2_SESSION *session)
{
    static const unsigned char types[] = { SSH_MSG_REQUEST_SUCCESS,
                                           SSH_MSG_REQUEST_FAILURE };
    int dropped = 0;
    size_t i;
    for(i = 0; i < sizeof(types); i++) {
        unsigned char *data;
        size_t len;
        while(_libssh2_packet_ask(session, types[i], &data, &len,
                                  0, NULL, 0) == 0) {
            LIBSSH2_FREE(session, data);
            dropped++;
        }
    }
    return dropped;
}
