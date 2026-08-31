// Native BlueZ D-Bus agent helper for Bluetooth pairing
#define _GNU_SOURCE
#include <dbus/dbus.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define AGENT_PATH "/org/noctalia/bluetooth_helper"
#define JSON_PATH "/tmp/noctalia_bt_pairing.json"
#define ACT_PATH "/tmp/noctalia_bt_pairing_action"

static void clean_files(void) {
  unlink(JSON_PATH);
  unlink(ACT_PATH);
}

static void sig_handler(int sig) {
  (void)sig;
  clean_files();
  _exit(0);
}

static void escape_json(const char *src, char *dst, size_t max) {
  size_t j = 0;
  for (size_t i = 0; src && src[i] && j + 2 < max; i++) {
    unsigned char c = (unsigned char)src[i];
    if (c == '"' || c == '\\') {
      dst[j++] = '\\';
      dst[j++] = c;
    } else if (c >= 32 && c <= 126) {
      dst[j++] = c;
    }
  }
  dst[j] = '\0';
}

static void open_panel(void) {
  pid_t pid = fork();
  if (pid == 0) {
    char *argv[] = {"noctalia", "msg", "panel-open",
                    "autumn/network-toolkit:panel", NULL};
    execvp("noctalia", argv);
    _exit(1);
  }
  if (pid > 0)
    waitpid(pid, NULL, WNOHANG);
}

static void get_device_info(DBusConnection *conn, const char *path, char *addr,
                            char *name) {
  strcpy(addr, "Unknown");
  strcpy(name, "Bluetooth Device");
  if (!path)
    return;
  const char *p = strstr(path, "dev_");
  if (p) {
    strncpy(addr, p + 4, 17);
    addr[17] = '\0';
    for (int i = 0; addr[i]; i++)
      if (addr[i] == '_')
        addr[i] = ':';
    snprintf(name, 64, "%s", addr);
  }
  if (conn && path) {
    DBusMessage *m = dbus_message_new_method_call(
        "org.bluez", path, "org.freedesktop.DBus.Properties", "Get");
    if (m) {
      const char *iface = "org.bluez.Device1";
      const char *prop = "Alias";
      dbus_message_append_args(m, DBUS_TYPE_STRING, &iface, DBUS_TYPE_STRING,
                               &prop, DBUS_TYPE_INVALID);
      DBusMessage *r =
          dbus_connection_send_with_reply_and_block(conn, m, 500, NULL);
      if (r) {
        DBusMessageIter iter, sub;
        if (dbus_message_iter_init(r, &iter) &&
            dbus_message_iter_get_arg_type(&iter) == DBUS_TYPE_VARIANT) {
          dbus_message_iter_recurse(&iter, &sub);
          if (dbus_message_iter_get_arg_type(&sub) == DBUS_TYPE_STRING) {
            const char *val = NULL;
            dbus_message_iter_get_basic(&sub, &val);
            if (val && *val)
              snprintf(name, 64, "%.63s", val);
          }
        }
        dbus_message_unref(r);
      }
      dbus_message_unref(m);
    }
  }
}

static void reply_flush(DBusConnection *c, DBusMessage *r) {
  if (!c || !r)
    return;
  dbus_connection_send(c, r, NULL);
  dbus_connection_flush(c);
  dbus_message_unref(r);
}

static int wait_user_action(DBusConnection *conn) {
  (void)conn;
  time_t t0 = time(NULL);
  while (time(NULL) - t0 < 30) {
    int fd = open(ACT_PATH, O_RDONLY | O_NOFOLLOW);
    if (fd >= 0) {
      FILE *f = fdopen(fd, "r");
      if (f) {
        char buf[32] = {0};
        if (fgets(buf, sizeof(buf), f)) {
          fclose(f);
          int accepted = (strcasestr(buf, "accept") || strcasestr(buf, "yes"));
          unlink(ACT_PATH);
          return accepted;
        }
        fclose(f);
      } else {
        close(fd);
      }
    }
    usleep(50000);
  }
  unlink(ACT_PATH);
  return 0;
}

static int handle_req(DBusConnection *conn, const char *dev_path,
                      const char *passkey, int wait) {
  unlink(ACT_PATH);
  char addr[64] = {0}, name[64] = {0};
  get_device_info(conn, dev_path, addr, name);
  char ea[128] = {0}, en[128] = {0}, ep[32] = {0};
  escape_json(addr, ea, sizeof(ea));
  escape_json(name, en, sizeof(en));
  escape_json(passkey ? passkey : "", ep, sizeof(ep));
  int fd = open(JSON_PATH, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
  if (fd >= 0) {
    FILE *f = fdopen(fd, "w");
    if (f) {
      fprintf(f,
              "{\"address\":\"%s\",\"name\":\"%s\",\"passkey\":\"%s\","
              "\"timestamp\":%ld}\n",
              ea, en, ep, (long)time(NULL));
      fflush(f);
      fclose(f);
    } else {
      close(fd);
    }
  }
  open_panel();
  if (!wait)
    return 1;
  int result = wait_user_action(conn);
  unlink(JSON_PATH);
  return result;
}

static void register_agent(DBusConnection *conn) {
  const char *path = AGENT_PATH, *cap = "DisplayYesNo";
  DBusMessage *m = dbus_message_new_method_call(
      "org.bluez", "/org/bluez", "org.bluez.AgentManager1", "RegisterAgent");
  if (m) {
    dbus_message_append_args(m, DBUS_TYPE_OBJECT_PATH, &path, DBUS_TYPE_STRING,
                             &cap, DBUS_TYPE_INVALID);
    DBusMessage *r =
        dbus_connection_send_with_reply_and_block(conn, m, 3000, NULL);
    if (r)
      dbus_message_unref(r);
    dbus_message_unref(m);
  }
  m = dbus_message_new_method_call("org.bluez", "/org/bluez",
                                   "org.bluez.AgentManager1",
                                   "RequestDefaultAgent");
  if (m) {
    dbus_message_append_args(m, DBUS_TYPE_OBJECT_PATH, &path,
                             DBUS_TYPE_INVALID);
    DBusError e;
    dbus_error_init(&e);
    DBusMessage *r =
        dbus_connection_send_with_reply_and_block(conn, m, 3000, &e);
    if (dbus_error_is_set(&e)) {
      // If default agent request failed, unregister and re-register
      dbus_error_free(&e);
      DBusMessage *unreg = dbus_message_new_method_call(
          "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
          "UnregisterAgent");
      if (unreg) {
        dbus_message_append_args(unreg, DBUS_TYPE_OBJECT_PATH, &path,
                                 DBUS_TYPE_INVALID);
        DBusMessage *ur =
            dbus_connection_send_with_reply_and_block(conn, unreg, 2000, NULL);
        if (ur)
          dbus_message_unref(ur);
        dbus_message_unref(unreg);
      }
      DBusMessage *reg2 = dbus_message_new_method_call(
          "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
          "RegisterAgent");
      if (reg2) {
        dbus_message_append_args(reg2, DBUS_TYPE_OBJECT_PATH, &path,
                                 DBUS_TYPE_STRING, &cap, DBUS_TYPE_INVALID);
        DBusMessage *rr =
            dbus_connection_send_with_reply_and_block(conn, reg2, 3000, NULL);
        if (rr)
          dbus_message_unref(rr);
        dbus_message_unref(reg2);
      }
      DBusMessage *def2 = dbus_message_new_method_call(
          "org.bluez", "/org/bluez", "org.bluez.AgentManager1",
          "RequestDefaultAgent");
      if (def2) {
        dbus_message_append_args(def2, DBUS_TYPE_OBJECT_PATH, &path,
                                 DBUS_TYPE_INVALID);
        DBusMessage *dr =
            dbus_connection_send_with_reply_and_block(conn, def2, 3000, NULL);
        if (dr)
          dbus_message_unref(dr);
        dbus_message_unref(def2);
      }
    } else {
      if (r)
        dbus_message_unref(r);
    }
    dbus_message_unref(m);
  }
}

static DBusHandlerResult agent_handler(DBusConnection *conn, DBusMessage *msg,
                                       void *data) {
  (void)data;
  const char *member = dbus_message_get_member(msg);
  if (!member)
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;

  // auto-approve profile authorization
  if (strcmp(member, "Release") == 0 ||
      strcmp(member, "AuthorizeService") == 0) {
    reply_flush(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "Cancel") == 0) {
    clean_files();
    reply_flush(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  // RequestConfirmation: 6-digit numeric comparison 
  if (strcmp(member, "RequestConfirmation") == 0) {
    const char *dev = NULL;
    dbus_uint32_t pk = 0;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_UINT32, &pk, DBUS_TYPE_INVALID);
    char pbuf[16];
    snprintf(pbuf, sizeof(pbuf), "%06u", pk);
    if (handle_req(conn, dev, pbuf, 1))
      reply_flush(conn, dbus_message_new_method_return(msg));
    else
      reply_flush(conn, dbus_message_new_error(msg, "org.bluez.Error.Rejected",
                                               "Rejected"));
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (strcmp(member, "RequestAuthorization") == 0) {
    const char *dev = NULL;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_INVALID);
    if (handle_req(conn, dev, "", 1))
      reply_flush(conn, dbus_message_new_method_return(msg));
    else
      reply_flush(conn, dbus_message_new_error(msg, "org.bluez.Error.Rejected",
                                               "Rejected"));
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (strcmp(member, "RequestPasskey") == 0) {
    const char *dev = NULL;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_INVALID);
    if (handle_req(conn, dev, "", 1)) {
      DBusMessage *r = dbus_message_new_method_return(msg);
      dbus_uint32_t pk = 0;
      dbus_message_append_args(r, DBUS_TYPE_UINT32, &pk, DBUS_TYPE_INVALID);
      reply_flush(conn, r);
    } else {
      reply_flush(conn, dbus_message_new_error(msg, "org.bluez.Error.Rejected",
                                               "Rejected"));
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (strcmp(member, "RequestPinCode") == 0) {
    const char *dev = NULL;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_INVALID);
    if (handle_req(conn, dev, "0000", 1)) {
      DBusMessage *r = dbus_message_new_method_return(msg);
      const char *pin = "0000";
      dbus_message_append_args(r, DBUS_TYPE_STRING, &pin, DBUS_TYPE_INVALID);
      reply_flush(conn, r);
    } else {
      reply_flush(conn, dbus_message_new_error(msg, "org.bluez.Error.Rejected",
                                               "Rejected"));
    }
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  if (strcmp(member, "DisplayPasskey") == 0) {
    const char *dev = NULL;
    dbus_uint32_t pk = 0;
    dbus_uint16_t ent = 0;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_UINT32, &pk, DBUS_TYPE_UINT16, &ent,
                          DBUS_TYPE_INVALID);
    char pbuf[16];
    snprintf(pbuf, sizeof(pbuf), "%06u", pk);
    handle_req(conn, dev, pbuf, 0);
    reply_flush(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  if (strcmp(member, "DisplayPinCode") == 0) {
    const char *dev = NULL;
    const char *pin = NULL;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_OBJECT_PATH, &dev,
                          DBUS_TYPE_STRING, &pin, DBUS_TYPE_INVALID);
    handle_req(conn, dev, pin ? pin : "", 0);
    reply_flush(conn, dbus_message_new_method_return(msg));
    return DBUS_HANDLER_RESULT_HANDLED;
  }

  // Re-register agent if BlueZ restarts
  if (strcmp(member, "NameOwnerChanged") == 0) {
    const char *n = NULL, *o = NULL, *nw = NULL;
    dbus_message_get_args(msg, NULL, DBUS_TYPE_STRING, &n, DBUS_TYPE_STRING, &o,
                          DBUS_TYPE_STRING, &nw, DBUS_TYPE_INVALID);
    if (n && strcmp(n, "org.bluez") == 0 && nw && *nw)
      register_agent(conn);
    return DBUS_HANDLER_RESULT_HANDLED;
  }
  return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

int main(void) {
  clean_files();
  signal(SIGTERM, sig_handler);
  signal(SIGINT, sig_handler);

  DBusError err;
  dbus_error_init(&err);
  DBusConnection *conn = dbus_bus_get(DBUS_BUS_SYSTEM, &err);
  if (!conn) {
    fprintf(stderr, "D-Bus: %s\n", err.message);
    return 1;
  }

  DBusObjectPathVTable vt = {.message_function = agent_handler};
  dbus_connection_register_object_path(conn, AGENT_PATH, &vt, NULL);
  dbus_connection_add_filter(conn, agent_handler, NULL, NULL);
  dbus_bus_add_match(conn, "type='method_call',interface='org.bluez.Agent1'",
                     &err);
  dbus_bus_add_match(conn,
                     "type='signal',sender='org.freedesktop.DBus',interface='"
                     "org.freedesktop.DBus',member='NameOwnerChanged'",
                     &err);

  register_agent(conn);

  while (dbus_connection_read_write_dispatch(conn, -1)) {
  }
  return 0;
}
